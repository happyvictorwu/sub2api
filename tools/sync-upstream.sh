#!/usr/bin/env bash
# =============================================================================
#  sync-upstream.sh — 同步上游 Wei-Shaw/sub2api
# =============================================================================
#
#  用法：
#     ./tools/sync-upstream.sh            拉上游、合并、重新剥离广告、核对差异
#     ./tools/sync-upstream.sh --check    只看上游有什么新东西，不改工作区
#
#  本仓库的不变式：**内容与上游逐字节一致，只保留下面这份已知差异**。
#  正因为不再有自有品牌，同步才只是一次 merge，不需要跑任何改名脚本。
#
#  已知差异（KNOWN_DELTA）：
#     · 树懒 logo             assets/logo.svg, frontend/public/logo.svg
#     · 主色与首页字标         frontend/tailwind.config.js, frontend/src/views/HomeView.vue
#     · Azure 部署方案         deploy/azure/*, .github/workflows/azure-deploy.yml,
#                             docs/AZURE_DEPLOY_CN.md, .gitignore 一行
#     · 默认设置初始化修复      backend/internal/service/{setting_parse,wire}.go 及其测试
#     · Rollup CI 时区稳定性  backend/internal/repository/group_usage_rollup_trigger_integration_test.go
#     · 摘除上游赞助商推广位    README*.md, assets/partners/, ProxyAdBanner 及其引用,
#                             tools/strip-upstream-ads.sh
#
#  脚本最后会把实际差异和这份清单比对。**出现清单之外的文件就是意外分叉**，
#  要么是合并时改错了，要么是该把它加进清单——不要放着不管。
# =============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MODE=sync
case "${1:-}" in
  --check) MODE=check ;;
  --help|-h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "未知参数: $1（试试 --help）" >&2; exit 2 ;;
esac

git remote get-url upstream >/dev/null 2>&1 \
  || { echo "没有配置 upstream remote。先跑：" >&2
       echo "  git remote add upstream https://github.com/Wei-Shaw/sub2api.git" >&2; exit 1; }

echo "==> 拉取上游"
git fetch upstream --prune

AHEAD=$(git rev-list --count HEAD..upstream/main)
if [[ "${AHEAD}" -eq 0 ]]; then
  echo "✅ 已经是最新，上游没有新提交。"
  exit 0
fi

echo
echo "==> 上游有 ${AHEAD} 个新提交，其中合并到 main 的 PR："
git log --oneline --first-parent HEAD..upstream/main | head -40
echo

if [[ "${MODE}" == check ]]; then
  echo "（--check 模式，未改动工作区）"
  exit 0
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "❌ 工作区不干净，先提交或 stash 再同步。" >&2
  exit 1
fi

echo "==> 合并 upstream/main"
if ! git merge upstream/main; then
  echo
  echo "❌ 有冲突。解决后执行：" >&2
  echo "     git add -A && git commit" >&2
  echo "     ./tools/sync-upstream.sh   # 再跑一次，完成后续的广告剥离与差异核对" >&2
  exit 1
fi

echo
echo "==> 重新剥离上游广告（上游可能加回了赞助位）"
./tools/strip-upstream-ads.sh
rm -rf _to_delete
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit -m "chore: 同步上游后重新剥离赞助商推广位"
fi

echo
echo "==> 核对与上游的实际差异"
ACTUAL=$(git diff --name-only upstream/main | grep -v '^assets/partners/' | sort)
EXPECTED=$(printf '%s\n' \
  '.github/workflows/azure-deploy.yml' \
  '.gitignore' \
  'README.md' 'README_CN.md' 'README_JA.md' \
  'assets/logo.svg' \
  'backend/internal/repository/group_usage_rollup_trigger_integration_test.go' \
  'backend/internal/service/setting_parse.go' \
  'backend/internal/service/setting_service_update_test.go' \
  'backend/internal/service/wire.go' \
  'docs/AZURE_DEPLOY_CN.md' \
  'docs/UPSTREAM_SYNC_CN.md' \
  'frontend/public/logo.svg' \
  'frontend/src/components/account/CreateAccountModal.vue' \
  'frontend/src/components/account/EditAccountModal.vue' \
  'frontend/src/components/account/__tests__/CreateAccountModal.spec.ts' \
  'frontend/src/components/common/ProxyAdBanner.vue' \
  'frontend/src/i18n/locales/en/admin/resources.ts' \
  'frontend/src/i18n/locales/zh/admin/resources.ts' \
  'frontend/src/views/HomeView.vue' \
  'frontend/src/views/admin/ProxiesView.vue' \
  'frontend/tailwind.config.js' \
  'tools/strip-upstream-ads.sh' \
  'tools/sync-upstream.sh' \
  | sort)
# deploy/azure/ 整目录都是我们自己的，逐个列没意义
UNEXPECTED=$(comm -23 <(echo "$ACTUAL" | grep -v '^deploy/azure/') <(echo "$EXPECTED") || true)

if [[ -z "${UNEXPECTED}" ]]; then
  echo "✅ 差异与清单一致，没有意外分叉。"
else
  echo "⚠️  清单之外的差异，请逐个确认是否有意为之："
  echo "${UNEXPECTED}" | sed 's/^/     /'
  echo "   （确认无误后把它们加进本脚本顶部的 KNOWN_DELTA 和下面的 EXPECTED 列表）"
fi

echo
echo "==> 接下来："
echo "   1. 检查上面列出的上游改动里有没有影响你的（尤其是迁移文件和破坏性变更）"
echo "   2. git push origin main   —— 会触发 CI 构建镜像并自动部署到 Azure"
