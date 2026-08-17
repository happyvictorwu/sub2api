# 品牌改名机制说明

本 fork 把上游 `Sub2API` 的品牌串统一到了一处配置。这份文档说明它怎么工作、
为什么某些地方**刻意不改**、以及你重新 fork 上游之后要做什么。

---

## TL;DR

```bash
vim brand.conf          # 改品牌
./tools/rebrand.sh      # 应用
```

重新 fork 上游之后：

```bash
# 在新 clone 里，把这 7 个文件拷过来
OLD=<旧仓库路径>
mkdir -p tools backend/internal/branding
cp "$OLD"/brand.conf "$OLD"/REBRAND.md .
cp "$OLD"/tools/rebrand.sh "$OLD"/tools/strip-upstream-ads.sh tools/
cp "$OLD"/backend/internal/branding/branding.go backend/internal/branding/
cp "$OLD"/backend/internal/service/branding.go   backend/internal/service/
cp "$OLD"/frontend/src/brand.ts                  frontend/src/
chmod +x tools/*.sh

./tools/rebrand.sh              # 改名
./tools/strip-upstream-ads.sh   # 去掉上游赞助商与广告
```

**7 个文件 + 2 条命令**，全部幂等，可反复运行。

---

## 涉及的文件

| 文件 | 角色 |
|---|---|
| `brand.conf` | **单一真源**。你唯一需要手改的文件 |
| `tools/rebrand.sh` | 幂等品牌替换脚本 |
| `tools/strip-upstream-ads.sh` | 幂等移除上游赞助商与广告的脚本 |
| `backend/internal/branding/branding.go` | 后端品牌常量（零依赖叶子包，支持环境变量运行时覆盖） |
| `backend/internal/service/branding.go` | `service` 包内的短别名 `brandName()` |
| `frontend/src/brand.ts` | 前端品牌常量 |

以上都是**本 fork 新增**的文件，上游没有，所以永远不会和上游产生冲突。

---

## 三条注入路径

品牌串出现的位置性质不同，只能用不同办法处理。

### 路径 1 · 运行时数据库设置（上游本来就有，零改动）

后台 **系统设置 → 站点名称**（`site_name`）。改完立刻生效，不用重启也不用重编译。

这一条覆盖了绝大多数用户可见的地方：页面标题、邮件发件人名、验证码邮件正文、
订单商品名、余额告警通知、内容审核提示等。

**日常改名应该优先用这个。** 下面两条只是它的兜底和补充。

### 路径 2 · 环境变量（本 fork 新增）

`site_name` 取不到值时的兜底默认值，现在走 `branding.Name()`，支持环境变量：

| 环境变量 | 作用 | 默认值来源 |
|---|---|---|
| `BRAND_NAME` | 产品名兜底 | `branding.go` 里的编译期常量 |
| `BRAND_TAGLINE` | HTML `<title>` 的副标题 | 同上 |

适用场景：数据库还没初始化（安装向导阶段）、多实例跑同一镜像但要显示不同品牌、
临时改名不想重新编译。

已改造成 `brandName()` 的位置共 15 处，分布在：

```
backend/internal/service/setting_features.go     GetSiteName 兜底
backend/internal/service/setting_parse.go        默认设置表 + 解析兜底
backend/internal/service/setting_public.go       公开设置兜底
backend/internal/service/auth_service.go         3 处邮件站点名
backend/internal/service/auth_email_binding.go   邮箱绑定验证码
backend/internal/service/auth_oauth_email_flow.go OAuth 注册验证码
backend/internal/service/user_service.go         通知验证邮件
backend/internal/service/content_moderation.go   2 处内容审核提示
backend/internal/service/payment_order.go        2 处订单商品名
```

> 为什么不是全部？`const` 块里的字面值（`totpIssuer`、`defaultSiteName`、
> `AdminComplianceAckPhrase*`）在 Go 里不能调用函数，只能由脚本做字面替换。
> 改这几个需要重新编译。

### 路径 3 · 构建期字面替换（脚本）

README、部署文件、docker-compose、i18n 文案、systemd unit、CI workflow、
config 示例……这些没有运行时注入的可能，只能替换源文件。这是 `tools/rebrand.sh` 干的活。

本次改动规模：**259 个文件**。

---

## ⚠️ 刻意不改的东西

脚本里有一份保护名单。每一条都有具体理由，**不要随便去掉**。

### 1. Go module path — `github.com/Wei-Shaw/sub2api`

约 1500 个文件的 import 行都是它。它不是商标，编译成二进制后对外完全不可见。

改了的唯一后果是：以后每次 `git merge upstream/main` 都会在 1500+ 个文件的
import 行上冲突，基本等于放弃跟进上游。上游有 5800+ commits、695 个 open PR、
迭代非常快，放弃跟进的代价远大于「彻底去除 Wei-Shaw 字样」的收益。

脚本对这一条有**硬断言**：如果 `backend/go.mod` 的 module 行被改动，脚本直接报错退出。

### 2. `backend/.golangci.yml` 里的包路径

```yaml
deny:
  - pkg: github.com/Wei-Shaw/sub2api/internal/repository
    desc: "service must not import repository"
```

这里写的是 Go 包路径，不是仓库地址。改了**不会报错**，只会让 depguard 规则
静默失配 —— 也就是本项目最重要的架构约束（service 层不得 import repository）
悄悄失效。属于最难发现的那类破坏。脚本对这一条同样有硬断言。

### 3. `sub2api/billing` 端点

```go
gateway.GET("/sub2api/billing", h.Gateway.KeyBillingInfo)   // /v1 来自 group 前缀
probeURL := buildOpenAIEndpointURL(baseURL, "/v1/sub2api/billing")
```

这是**跨站点协议**：本站点用它去查询「上游其他 sub2api 站点」为当前 API Key
声明的计费倍率，上游站点也用它来响应本站点。改了就无法和任何上游中转站互通。

注意保护串写的是 `sub2api/billing` 而不是 `/v1/sub2api/billing` —— 路由注册处
没有 `/v1` 前缀（它来自 group），只保护带 `/v1` 的写法会漏掉真正的注册点。

### 4. `SUB2API_PROMPT_AUDIT_PRIORITY_END`

prompt 审计快照的内部分隔符（`internal/securityaudit/prompt_snapshot.go`）。
改了会导致已经入库的历史快照无法解析。

### 5. 内部环境变量名 `SUB2API_*`

18 个：`SUB2API_JWT`、`SUB2API_ADMIN_API_KEY`、`SUB2API_DEBUG_GATEWAY_BODY`、
`SUB2API_DEVICECHECK_MODULE`、`SUB2API_DEV_HTTP_PROXY` 等。

默认不改名。它们不对外可见，改了只会让你搜上游 issue、对照上游文档时全部失配。
想改就在 `brand.conf` 里设 `BRAND_RENAME_ENV_VARS=1`。

### 6. 第三方地址

| 地址 | 是什么 |
|---|---|
| `tls.sub2api.org` | 第三方在线工具，管理后台「TLS 指纹」弹窗直接链出去的真实站点 |
| `sub2api.io/proxyip` | 第三方代理广告位 |
| `novada.com/?sub2api/` | 赞助商链接 |
| `github.com/ckken/sub2api-mobile` | 别人的移动端项目 |
| `github.com/touwaeriol/sub2apipay` | 别人的支付项目 |

### 7. 赞助商推广码

`aff=SUB2API`、`promo=SUB2API`、`?ref=sub2api`、`invite/SUB2API`、`code=SUB2API`

这些是上游作者的返佣位。改了链接失效，而且等于冒用别人的推广位。
正确做法是**整段删除而不是改写** —— 交给 `tools/strip-upstream-ads.sh`。

---

## brand.conf 各项说明

| 键 | 说明 |
|---|---|
| `BRAND_NAME` | 产品名。所有用户可见处 |
| `BRAND_SLUG` | 小写标识符。docker 镜像/容器名、数据库名、redis key 前缀、日志服务名、systemd 服务名、npm 包名。校验：只允许 `[a-z0-9-]`，且不能含 `sub2api`（否则替换自我循环） |
| `BRAND_ENV_PREFIX` | 大写前缀。仅当 `BRAND_RENAME_ENV_VARS=1` 时生效 |
| `BRAND_DOMAIN` | 主域名。留空 → `${BRAND_SLUG}.example.com` |
| `BRAND_SUPPORT_EMAIL` | 联系邮箱。留空 → `support@${BRAND_DOMAIN}` |
| `BRAND_GITHUB_REPO` | 你的仓库 `owner/repo`。文档里指向上游的链接会改指到这里 |
| `BRAND_TAGLINE` | HTML `<title>` 的副标题 |
| `BRAND_DOCKER_IMAGE` | docker 镜像名。上游的 `weishaw/sub2api` 换成这个 |
| `BRAND_RENAME_PATHS` | 默认 `0`。是否重命名带品牌的文件/目录（`deploy/sub2api.service`、`skills/sub2api-admin/`）。路径重命名是 merge 冲突的最大来源，和「保留 module path 以维持可合并性」的取舍相矛盾，所以默认关 |
| `BRAND_REWRITE_READMES` | 默认 `1`。是否改写三个 README |
| `BRAND_RENAME_ENV_VARS` | 默认 `0`。见上面第 5 条 |

留空项一律派生成 `example.com`（RFC 2606 保留域名），**肉眼就能看出是占位符**，
不会伪装成真实地址混进生产配置。

---

## 脚本用法

```bash
./tools/rebrand.sh              # 应用
./tools/rebrand.sh --dry-run    # 只列出会改哪些文件
./tools/rebrand.sh --verify     # 检查还有哪些漏网的品牌串
./tools/rebrand.sh --help
```

### 幂等性

所有替换规则的左手边都是**上游原始字面值**（`Sub2API` / `sub2api` / `Wei-Shaw/sub2api`
…），不是「旧品牌 → 新品牌」。所以：

* 同一个仓库跑 1 次和跑 10 次结果完全一样（已验证：第二、三次都是 0 个修改）
* 重新 fork 上游之后直接跑，不需要任何迁移步骤
* 改了 `brand.conf` 想换个品牌名，需要先 `git checkout` 回未改名状态再跑
  （因为规则认的是上游字面值，不认你的旧品牌）

> 实现上有个坑值得说明：`BRAND_GITHUB_REPO` 通常形如 `you/sub2api` ——
> 仓库名本身就含 `sub2api`。所以脚本会把「本次要插入的新值」也一起掩码保护，
> 否则通用规则会把它二次替换成 `you/slothwatching`，幂等性就没了。

### 每次改完必做的验证

```bash
git diff --stat
cd backend && go build ./...
pnpm --dir frontend run typecheck
```

---

## tools/strip-upstream-ads.sh 做什么

`rebrand.sh` 只改字面值，**刻意不动**赞助商推广码（改掉链接里的 `aff=SUB2API`
等于冒用别人的返佣位）。正确做法是整段删除 —— 这是本脚本的职责。

它做三件事，全部幂等：

1. 摘除 `README.md` / `README_CN.md` / `README_JA.md` 的「赞助商」整节
   （合计约 450 行，三个 README 体积从 145KB 降到 78KB），原文存档到
   `_to_delete/readme-sponsors/`
2. 移除 `ProxyAdBanner` 组件（上游的第三方代理广告，链接指向 `sub2api.io/proxyip`）
   及其全部 7 处引用：3 处模板、3 处 import、1 处测试 stub，外加 en/zh 两处
   i18n 文案 `admin.proxies.ad.inline`
3. 把 `assets/partners/`（31 个赞助商 logo，2.7MB）挪走

**删除策略是移动到 `_to_delete/`，不直接删** —— 你可以先过一眼再统一
`rm -rf _to_delete`，也兼容无法 unlink 的挂载环境。

```bash
./tools/strip-upstream-ads.sh --dry-run   # 先看会做什么
./tools/strip-upstream-ads.sh
```

## 仍需你人工处理的

1. **Logo 图形文件** — `assets/logo.svg` 和 `frontend/public/logo.svg` 是上游的
   图形标识，脚本没法替你画。换成你自己的 logo 文件。
   （管理后台也支持上传 `site_logo` 做运行时覆盖，不必改文件。）

2. **CLA** — `CLA.md` + `.github/workflows/cla.yml` 是上游的贡献者协议流程。
   自用 fork 不需要，可以删掉 workflow。

3. **`docs/legal/*.md`** — 合规承诺文档正文里的品牌名已替换，但条款内容是
   上游针对自己的表述。如果你要对外提供服务，这些应该自己重写。

---

## 跟进上游

```bash
git fetch upstream
git merge upstream/main          # 或 rebase
./tools/rebrand.sh               # 把上游新引入的品牌串也换掉
./tools/strip-upstream-ads.sh    # 上游若加了新赞助商，一并清掉
git diff --stat                  # 确认改动符合预期
cd backend && go build ./...
```

合并时的冲突范围应该只落在你**真正修改过业务逻辑**的文件上。品牌替换本身
不会造成冲突堆积 —— 因为 module path 没动，而字面替换的结果每次都由脚本
重新生成。
