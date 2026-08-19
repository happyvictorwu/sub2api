# 同步上游

本仓库是 [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api) 的 fork。

**不变式：内容与上游逐字节一致，只保留一份已知的小差异。** 不再维护自有品牌，
所以同步就是一次 `git merge`，不需要跑任何改名脚本。

## 日常同步

```bash
./tools/sync-upstream.sh --check   # 先看上游有什么新东西
./tools/sync-upstream.sh           # 拉取、合并、重新剥离广告、核对差异
```

脚本最后会把实际差异和已知清单比对。**出现清单之外的文件就是意外分叉**——
要么是合并时改错了，要么是该把它加进清单，不要放着不管。

确认无误后 `git push origin main`，CI 会自动构建镜像并部署到 Azure。

## 已知差异

| 类别 | 文件 |
|------|------|
| 树懒 logo | `assets/logo.svg`、`frontend/public/logo.svg` |
| 主色与首页字标 | `frontend/tailwind.config.js`（primary 色阶改暖褐琥珀）、`frontend/src/views/HomeView.vue`（logo 旁 "slow watching" 字标） |
| Azure 部署方案 | `deploy/azure/*`、`.github/workflows/azure-deploy.yml`、`docs/AZURE_DEPLOY_CN.md`、`.gitignore` 一行 |
| 默认设置初始化修复 | `backend/internal/service/setting_parse.go`、`wire.go` 及其测试 |
| Rollup CI 时区稳定性 | `backend/internal/repository/group_usage_rollup_trigger_integration_test.go` |
| 摘除赞助商推广位 | `README*.md`、`assets/partners/`、`ProxyAdBanner` 及其引用、`tools/strip-upstream-ads.sh` |

差异清单的**权威来源是 [`tools/sync-upstream.sh`](../tools/sync-upstream.sh) 里的 `EXPECTED` 数组**，
本表只是给人看的摘要。改了差异面就同时改那个数组。

## 冲突高发点

按上游半年的改动频率排：

- `frontend/src/views/HomeView.vue` —— 上游半年动 1 次，冲突时保留我们的 logo 区和字标即可
- `frontend/tailwind.config.js` —— 上游一年动 1 次，冲突时只保留我们的 `primary` 色阶和 `gradient-primary`
- `backend/internal/service/setting_parse.go` —— 上游偶尔加新的默认设置项。冲突时保留上游新增的键，
  同时保留我们那段"只补缺失的键"的逻辑（上游至今仍未修这个缺陷）
- 其余（`deploy/azure/*`、logo、`tools/*`）上游根本没有这些文件，永远不会冲突

## 为什么不再有改名脚本

早期做过一次全量改名（Sub2API → 自有品牌），代价是 300 个文件的永久分叉，
每次同步都要重跑脚本、还踩过两个坑：改名脚本会把已应用的迁移文件注释改掉，
导致 `migrations_runner` 校验和不匹配、应用拒绝启动；也会把 GHCR 镜像路径和
上游仓库名一起改错。回退品牌后这些问题一次性消失。

要做视觉差异化，优先用**不改代码**的手段：管理员设置里的站点名、Logo、
首页自定义内容（`home_content`，支持整页 HTML 或 iframe）都是运行时配置。
只有这些满足不了时，才考虑动 `tailwind.config.js` 和 `HomeView.vue`。
