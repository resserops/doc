#!/usr/bin/env bash
# ==============================================================================
# sync.sh — doc 笔记库自动同步 GitHub（手动/定时同一入口）
#
# 位置: ~/web/ignis/vaults/doc/sync.sh（住在仓库根，随笔记一起进 GitHub）
# 方案: 见 ~/build/ignis/同步方案.md
#
# 流程（标准 git 工作流，无 force，无特例分支）:
#   flock 防重入
#   → git init（幂等）/ 配 remote / 身份
#   → fetch 远端
#   → 本地 develop 对齐远端状态:
#       远端 develop 存在 → 基于它（后续提交父节点 = 远端最新，纯增量）
#       远端 develop 不存在 → 基于远端默认分支（main），即"首次同步"
#   → git add -A 差异检测，无变更零动作退出
#   → commit（单行 message）→ push（fast-forward）
#   → gh 建 PR develop → main → merge
#
# 前置（一次性）:
#   - doc 仓库为 private，且已在 GitHub 创建
#   - gh 已安装且 gh auth login 完成（选 SSH 协议，复用现有 key）
#
# 用法:
#   ./sync.sh                    # 手动触发
#   cron: 0 2 * * * ~/web/ignis/vaults/doc/sync.sh >> ~/web/ignis/logs/sync-doc.log 2>&1
# ==============================================================================
set -euo pipefail

# ----------------------------- 可配置项 ---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"                        # 脚本就住在仓库根（doc 库内）
LOG_DIR="$(dirname "${SCRIPT_DIR}")/../logs"    # 日志放仓库外（~/web/ignis/logs，不进 git）
LOCK_FILE="$(dirname "${SCRIPT_DIR}")/../.sync-doc.lock"
GITHUB_SSH="git@github.com:resserops/doc.git"    # SSH remote 地址
BRANCH="develop"                                # 本地+远端工作分支（同名直推）
TARGET_BRANCH="main"                            # 保护分支（PR 目标）
# 提交/PR 标题格式: docs: auto-sync <N> files from ignis at <时间>（单行，无中文）
RETRY_MAX=3                                     # push/PR/merge 重试次数

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [warn] $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [fail] $*" >&2; exit 1; }

# 带重试执行（国内推 GitHub 网络抖动，间隔 5s/15s/30s 递增）
retry() {
  local desc="$1"; shift
  local delays=(5 15 30)
  for i in $(seq 1 "${RETRY_MAX}"); do
    if "$@"; then return 0; fi
    local d="${delays[$((i-1))]:-30}"
    warn "${desc} attempt ${i}/${RETRY_MAX} failed, retry in ${d}s..."
    sleep "${d}"
  done
  die "${desc} failed after ${RETRY_MAX} retries (local commit kept, next run will resume)"
}

# 防止重入
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  warn "another sync process is running, exit"
  exit 0
fi

mkdir -p "${LOG_DIR}"
cd "${REPO_DIR}" 2>/dev/null || die "dir not found: ${REPO_DIR}"

# 初始化仓库
# git init 对已存在的仓库是 no-op（re-initialize 不动任何东西），
# 因此无需区分首次/后续——统一执行
git init -b "${BRANCH}" >/dev/null 2>&1 || git init >/dev/null

# remote 每次重配（幂等，地址改动只改上面的 GITHUB_SSH 变量）
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "${GITHUB_SSH}"

# 提交身份（仓库级配置，不依赖全局 gitconfig 是否设置）
git config --get user.name  >/dev/null 2>&1 || git config user.name  "sync"
git config --get user.email >/dev/null 2>&1 || git config user.email "sync@localhost"

# ----------------------------- 对齐远端 ---------------------------------------
# develop 永远基于远端 main（权威历史）增量提交：
#   main 是唯一累积历史的分支；develop 只是"main 最新 + 本次 1 个 commit"的 PR 载体。
#   每轮 sync: fetch → reset --soft origin/main → 笔记变更叠加 → 1 个 commit
#   → PR merge → main 增 1 个 merge commit（经典 PR 工作流）
retry "fetch" git fetch origin --prune
BASE_REF=""
if git rev-parse --verify -q origin/"${TARGET_BRANCH}" >/dev/null; then
  BASE_REF="origin/${TARGET_BRANCH}"
  log "basing on ${TARGET_BRANCH}"
fi

if [[ -n "${BASE_REF}" ]]; then
  # 软对齐：分支指向远端最新，工作区（笔记内容）原封不动——
  # 工作区是权威源，远端历史是提交父节点
  git reset --soft "${BASE_REF}" 2>/dev/null || {
    # 首次（本地无任何提交）soft 会失败，改用 checkout -B 从远端建分支
    git checkout -B "${BRANCH}" "${BASE_REF}" 2>/dev/null || true
  }
fi

# ----------------------------- 差异检测 ---------------------------------------
# 注意基线是 origin/main：与"上次 develop"的对比无关——比较对象永远是
# "当前 vault 内容" vs "main 已收录内容"，main 已含的内容不构成变更
git add -A
if git diff --cached --quiet 2>/dev/null && [[ -n "${BASE_REF}" ]]; then
  log "no changes, nothing to do"
  exit 0
fi

# ----------------------------- 提交 --------------------------------------------
# 单行、无中文：
#   docs: auto-sync 3 files from ignis at 2026-11-25 02:08:15
# 文件数 = 本次变更文件数（增量语义，符合标准 git 模型）
N_FILES=$(git diff --cached --name-only | wc -l)
STAMP=$(date '+%Y-%m-%d %H:%M:%S')
MSG="docs: auto-sync ${N_FILES} files from ignis at ${STAMP}"
git commit -m "${MSG}" >/dev/null
log "committed: ${MSG}"

# 不变量校验：本次推送恰好领先远端 1 个 commit。
# reset --soft 已保证基线 = 远端最新，commit 又只有一次，正常恒为 1；
# 超过 1 说明有脚本外的手动 commit 混入（或压平逻辑失效），拒绝推送并报错
if [[ -n "${BASE_REF}" ]]; then
  AHEAD=$(git rev-list --count "${BASE_REF}..HEAD")
  if [[ "${AHEAD}" -ne 1 ]]; then
    die "invariant broken: ${AHEAD} commits ahead of ${BASE_REF}, expected 1 (manual commits mixed in?)"
  fi
fi

# ----------------------------- 推送（force） ------------------------------------
# develop 每轮都从 main 最新重造，旧 develop 状态无意义——直接 force 覆盖。
# 这不是破坏性操作：develop 只是 PR 载体，权威历史在 main 和本地 vault
retry "push ${BRANCH}" \
  git push -f origin "${BRANCH}"

# ----------------------------- PR + merge 进 main ------------------------------
# 普通 merge：main 上落 merge commit + 内容 commit（经典 PR 工作流形态）
# 每轮 sync: main 增 1 个 merge commit，develop 的内容 commit 挂在其下
PR_NUM=$(gh pr list --head "${BRANCH}" --base "${TARGET_BRANCH}" \
          --json number -q '.[0].number' 2>/dev/null || true)
if [[ -z "${PR_NUM}" ]]; then
  PR_URL=$(retry "create PR" gh pr create \
      --head "${BRANCH}" --base "${TARGET_BRANCH}" \
      --title "${MSG}" \
      --body "${MSG}")
  log "PR created: ${PR_URL}"
else
  log "reuse existing PR #${PR_NUM}"
fi

retry "merge PR" \
  gh pr merge "${BRANCH}" --merge --delete-branch=false

log "merged into ${TARGET_BRANCH}, sync done: ${MSG}"
