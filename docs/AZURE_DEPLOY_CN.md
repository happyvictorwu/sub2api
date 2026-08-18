# Azure 部署指南（GitHub CI/CD）

面向场景：**10 人以内团队内部使用**，先用 Azure 默认域名跑起来，之后再换自有域名。

---

## 一、方案选型

### 最终方案：单台 Azure VM + Docker Compose + Caddy + GitHub Actions

```
                    Internet
                       │
                       ▼  HTTPS (Let's Encrypt 自动签发)
        ┌──────────────────────────────────────────┐
        │  Azure VM (Ubuntu 24.04, Standard_B2s)   │
        │  xxx.southeastasia.cloudapp.azure.com    │
        │                                          │
        │   ┌────────┐   ┌───────────────┐         │
        │   │ Caddy  │──▶│ sub2api │         │
        │   │ :80    │   │    :8080      │         │
        │   │ :443   │   └───────┬───────┘         │
        │   └────────┘           │                 │
        │                 ┌──────┴──────┐          │
        │                 ▼             ▼          │
        │           ┌──────────┐  ┌──────────┐     │
        │           │ Postgres │  │  Redis   │     │
        │           └──────────┘  └──────────┘     │
        └──────────────────────────────────────────┘
                       ▲
                       │ SSH 部署
        ┌──────────────────────────────────────────┐
        │  GitHub Actions: build → GHCR → deploy   │
        └──────────────────────────────────────────┘
```

### 为什么不用 Azure Container Apps / App Service

评估过更"云原生"的两个方案，都有一个对本项目致命的限制：

| 方案 | 关键问题 |
|------|---------|
| **Container Apps（消费计划）** | Ingress 请求超时固定 **240 秒且不可调**。要放宽必须升级到 Premium Ingress，而它要求 workload profile 环境 + 至少 2 个 D4 节点，每月多花 200 美元以上。 |
| **App Service for Containers** | 同样有约 **230 秒**的前端超时限制，同样不可调。 |
| **单台 VM（本方案）** | 没有平台层代理超时；Caddy 的超时完全由我们自己控制。 |

Sub2API 是 AI API 网关，大量请求是长时间 SSE 流式响应，非流式的长思考请求也常常超过 4 分钟。所以选择没有平台硬超时的 VM 方案。

另外三个次要理由：

- 仓库本身自带 `deploy/docker-compose.yml`、`Caddyfile`、systemd 单元，就是按单机部署设计的，摩擦最小；
- Postgres 和 Redis 跑在同机容器里，不用单独买托管服务（**注意**：Azure Cache for Redis 的 Basic/Standard/Premium 已于 2026 年 4 月对新订阅停止创建，2028 年 9 月 30 日退役，新建只能用更贵的 Azure Managed Redis）；
- 成本约为托管方案的一半。

### 成本估算（东南亚区域，每月）

| 项目 | 规格 | 约合美元/月 |
|------|------|------------|
| 虚拟机 | Standard_B2s（2 vCPU / 4 GiB） | ~$31 |
| 系统盘 | 64 GB StandardSSD_LRS | ~$5 |
| 公网 IP | Standard 静态 | ~$4 |
| 出网流量 | 轻量使用（前 100 GB 免费） | ~$0 |
| GitHub Actions / GHCR | 公开仓库免费 | $0 |
| **合计** | | **≈ $40** |

对比 Container Apps 全托管方案（含托管 Postgres + Managed Redis）约 $65–90/月。

> 想再省一点：把 VM 换成 `Standard_B2als_v2`（AMD，2 vCPU / 4 GiB）约 $25/月，
> `VM_SIZE=Standard_B2als_v2 ./bootstrap.sh` 即可。

---

## 二、交付的文件

| 文件 | 作用 |
|------|------|
| `deploy/azure/main.bicep` | 基础设施：VNet / NSG / 静态公网 IP（带 DNS 标签）/ Ubuntu VM |
| `deploy/azure/cloud-init.yaml` | 开机自动安装 Docker + Compose、配置 swap 与日志轮转 |
| `deploy/azure/bootstrap.sh` | **一次性**初始化脚本：建资源、生成密钥、写 `.env`、输出 GitHub Secrets |
| `deploy/azure/docker-compose.azure.yml` | Compose 覆盖层：换成 GHCR 镜像 + 加 Caddy |
| `deploy/azure/Caddyfile` | 自动 HTTPS 反向代理，针对 SSE 流式响应做过调整 |
| `deploy/azure/env.azure.example` | 环境变量模板 |
| `deploy/azure/remote-deploy.sh` | VM 上执行的部署脚本（备份 → 拉镜像 → 滚动更新 → 健康检查） |
| `deploy/azure/migrate-from-slothwatching.sh` | **一次性**迁移脚本：把早期按旧品牌建的部署换成 sub2api 命名并清理旧资源，跑完即可删除 |
| `.github/workflows/azure-deploy.yml` | CI/CD：push 到 main 自动构建镜像并部署 |

---

## 三、前置准备

1. **一个 Azure 订阅**，账号在目标订阅上至少是 Contributor。
2. **本机安装 Azure CLI** 并登录：

   ```bash
   # macOS
   brew install azure-cli
   az login
   az account show          # 确认当前订阅正确
   az account set --subscription "<订阅名或ID>"   # 如需切换
   ```

3. 代码已经在 `https://github.com/happyvictorwu/sub2api`（本文档就在这个仓库里）。

---

## 四、第一步：一次性初始化基础设施

```bash
cd deploy/azure
./bootstrap.sh
```

默认参数：区域 `southeastasia`（新加坡）、规格 `Standard_B2s`、资源组 `sub2api-rg`、时区 `Asia/Singapore`。

> **现存环境的命名例外**：本仓库早期用过一个自有品牌，那套 Azure 资源是用 `slothwatching`
> 前缀建的——资源组 `slothwatching-rg`、VM `slothwatching-vm`、NSG `slothwatching-nsg`、
> SSH 私钥 `~/.ssh/slothwatching_azure`，公网 DNS 标签同理。Azure 的资源组和 VM 都不支持改名，
> 重建又会换掉公网 IP 和域名，所以这些**保持原样**。本文档和脚本里的 `sub2api-*` 是全新
> provisioning 时的默认值；对现存环境执行 `az` 命令时，把资源名换成上面这组实际值。
> VM 内部（`/opt/sub2api`、容器名、数据库名、数据卷）已经统一到 sub2api，无例外。
需要修改时用环境变量覆盖：

```bash
LOCATION=eastasia \
VM_SIZE=Standard_B2ms \
ADMIN_EMAIL=you@yourcompany.com \
SSH_ALLOWED_CIDR="203.0.113.7/32" \
./bootstrap.sh
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RESOURCE_GROUP` | `sub2api-rg` | 资源组名 |
| `LOCATION` | `southeastasia` | 区域 |
| `VM_SIZE` | `Standard_B2s` | VM 规格 |
| `OS_DISK_SIZE_GB` | `64` | 系统盘 |
| `DNS_LABEL` | 自动随机 | 决定最终域名 `<label>.<region>.cloudapp.azure.com` |
| `ADMIN_USERNAME` | `azureuser` | VM 登录用户 |
| `SSH_KEY` | `~/.ssh/sub2api_azure` | 不存在会自动生成 |
| `SSH_ALLOWED_CIDR` | `*` | **建议改成你的固定出口 IP** |
| `ADMIN_EMAIL` | `admin@example.com` | 后台管理员账号 + Let's Encrypt 邮箱 |
| `TIMEZONE` | `Asia/Singapore` | 影响统计口径和订阅到期时间 |

脚本会依次完成：

1. 生成 SSH 密钥（如果没有）
2. 创建资源组并部署 Bicep（2–4 分钟）
3. 等待 cloud-init 装好 Docker（2–5 分钟）
4. 生成随机的 `POSTGRES_PASSWORD` / `REDIS_PASSWORD` / `JWT_SECRET` / `TOTP_ENCRYPTION_KEY` / 管理员初始密码，写入 VM 的 `/opt/sub2api/.env`
5. 打印需要填到 GitHub 的三个 Secret

> ⚠️ **管理员初始密码只会打印一次**，请立刻保存。
> `.env` 只存在于 VM 上（`/opt/sub2api/.env`，权限 600），不会进 Git。

如果 `.env` 已存在，脚本不会覆盖——重复执行 `bootstrap.sh` 是安全的。

---

## 五、第二步：配置 GitHub Secrets

在仓库 **Settings → Secrets and variables → Actions → New repository secret** 添加：

| Secret 名 | 值 |
|-----------|-----|
| `AZURE_VM_HOST` | `xxx.southeastasia.cloudapp.azure.com`（bootstrap 输出） |
| `AZURE_VM_USER` | `azureuser` |
| `AZURE_VM_SSH_KEY` | `~/.ssh/sub2api_azure` 私钥的完整内容（含 `-----BEGIN`/`-----END` 行） |

装了 `gh` CLI 的话可以直接：

```bash
gh secret set AZURE_VM_HOST   --body "xxx.southeastasia.cloudapp.azure.com"
gh secret set AZURE_VM_USER   --body "azureuser"
gh secret set AZURE_VM_SSH_KEY < ~/.ssh/sub2api_azure
```

不需要配置任何 Azure 凭据——CI 只通过 SSH 部署，不调用 Azure API。

---

## 六、第三步：首次部署

推送到 `main` 会自动触发，也可以手动跑：

**Actions → Deploy to Azure → Run workflow**

流水线两个阶段：

1. **Build & push image** — 用仓库根目录的多阶段 `Dockerfile` 构建（前端 pnpm 打包 → Go 编译内嵌前端 → Alpine 运行时），推送到 `ghcr.io/happyvictorwu/sub2api:sha-xxxxxxx` 和 `:latest`。首次约 8–15 分钟，之后有 buildx 缓存，通常 3–6 分钟。
2. **Deploy to VM** — SSH 到 VM，同步 compose 文件，备份数据库，拉新镜像，`docker compose up -d`，等待容器 healthy，最后对 `https://<域名>/health` 做冒烟测试。

部署成功后访问：

```
https://xxx.southeastasia.cloudapp.azure.com
```

用 bootstrap 输出的管理员邮箱和初始密码登录，**第一件事是改密码**。

> Let's Encrypt 首次签发证书需要 30 秒到 2 分钟。如果冒烟测试报 warning 但容器已经起来，稍等再刷新即可。

### 手动重新部署（不重新构建）

**Actions → Deploy to Azure → Run workflow → 勾选 skip_build**，会直接用 `:latest` 重新拉起。

---

## 七、日常运维

先登录 VM：

```bash
ssh -i ~/.ssh/sub2api_azure azureuser@xxx.southeastasia.cloudapp.azure.com
cd /opt/sub2api
```

为方便，可以先定义别名：

```bash
alias dc='docker compose -f docker-compose.yml -f docker-compose.azure.yml'
```

| 操作 | 命令 |
|------|------|
| 查看状态 | `dc ps` |
| 应用日志 | `dc logs -f sub2api` |
| Caddy 日志（排查证书） | `docker logs -f sub2api-caddy` |
| 重启应用 | `dc restart sub2api` |
| 全部重启 | `dc up -d --force-recreate` |
| 修改配置 | `nano .env` 然后 `dc up -d` |
| 进入容器 | `docker exec -it sub2api sh` |
| 磁盘占用 | `df -h && docker system df` |

### 修改配置

应用启用了 `viper.AutomaticEnv()`，`.env` 里的环境变量会**覆盖** `/app/data/config.yaml` 里的同名配置项，所以改 `.env` 后 `dc up -d` 即可生效，不需要动容器内的配置文件。

### 数据备份

每次部署前 `remote-deploy.sh` 会自动做一次数据库快照，存在 `/opt/sub2api/backups/`，保留最近 7 份。

手动备份：

```bash
cd /opt/sub2api
source .env
docker exec sub2api-postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  | gzip > "backups/manual-$(date +%Y%m%d).sql.gz"
```

恢复：

```bash
cd /opt/sub2api
source .env
gunzip -c backups/xxx.sql.gz | docker exec -i sub2api-postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

建议再加一层：在 Azure 门户为该 VM 打开 **Backup**（Recovery Services vault），做整机每日快照，约 $5/月。

### 回滚到上一个版本

```bash
cd /opt/sub2api
# 查看本地已有的镜像标签
docker images ghcr.io/happyvictorwu/sub2api
# 改成想回滚的 sha 标签
sed -i 's|^APP_IMAGE=.*|APP_IMAGE=ghcr.io/happyvictorwu/sub2api:sha-abc1234|' .env
docker compose -f docker-compose.yml -f docker-compose.azure.yml up -d
```

### 升级 VM 规格

```bash
az vm resize -g sub2api-rg -n sub2api-vm --size Standard_B4ms
```

会重启 VM，容器 `restart: unless-stopped` 会自动拉起，数据在托管盘上不丢。

---

## 八、换成自有域名

1. 在你的 DNS 服务商添加一条 CNAME（或 A 记录指向 VM 公网 IP）：

   ```
   api.yourdomain.com   CNAME   xxx.southeastasia.cloudapp.azure.com
   ```

2. 登录 VM 修改 `.env`：

   ```bash
   SITE_ADDRESS=api.yourdomain.com
   SITE_URL=https://api.yourdomain.com
   ```

3. 重启 Caddy，它会自动为新域名申请证书：

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.azure.yml up -d caddy
   ```

4. 同步更新 GitHub Secret `AZURE_VM_HOST`（冒烟测试用的是这个地址）。

> 需要同时保留两个域名时，把 `SITE_ADDRESS` 写成逗号分隔即可，例如
> `SITE_ADDRESS="api.yourdomain.com, xxx.southeastasia.cloudapp.azure.com"`。

---

## 九、常见问题

**Q: Actions 卡在 `Configure SSH`，报无法连接 22 端口**
检查 NSG 的 SSH 来源限制。如果 bootstrap 时设了 `SSH_ALLOWED_CIDR` 为固定 IP，GitHub Actions 的 runner IP 会被挡掉。GitHub runner 出口 IP 不固定，两种解法：把 SSH 规则放开为 `*`（依赖密钥认证保证安全），或改用自托管 runner。

```bash
az network nsg rule update -g sub2api-rg --nsg-name sub2api-nsg \
  -n AllowSSH --source-address-prefixes '*'
```

**Q: 网站打不开 / 证书报错**

```bash
docker logs sub2api-caddy | tail -50
```
常见原因：DNS 还没生效、80 端口被 NSG 挡住、`SITE_ADDRESS` 写错。Let's Encrypt 的 HTTP-01 校验必须能访问 80 端口。

**Q: 应用起不来，healthcheck 一直 unhealthy**

```bash
docker compose -f docker-compose.yml -f docker-compose.azure.yml logs sub2api | tail -100
```
多半是 `.env` 里数据库或 Redis 密码不匹配。删掉容器内已生成的配置重来：

```bash
docker exec sub2api rm -f /app/data/config.yaml
docker compose -f docker-compose.yml -f docker-compose.azure.yml restart sub2api
```

**Q: 重跑 `bootstrap.sh` 报 `PropertyChangeNotAllowed: osProfile.customData`**
Azure 不允许修改已存在 VM 的 cloud-init（customData）。脚本现在会先检测 VM 是否存在、存在就跳过部署，所以正常重跑不会再遇到。如果你确实改了 `cloud-init.yaml` 并想让它生效，只能删掉 VM 重建（数据在容器卷里，会一起丢，务必先备份）：

```bash
az vm delete -g sub2api-rg -n sub2api-vm --yes
./bootstrap.sh
```

> 顺带一提：`bootstrap.sh` 的 DNS 标签现在会优先复用已存在公网 IP 的标签，不会每次重跑换域名。

**Q: 忘了管理员密码**
`.env` 里的 `ADMIN_PASSWORD` 只在数据库为空时生效。已有数据时需要进数据库改，或用应用自带的 CLI（见 `DEV_GUIDE.md`）。

**Q: 构建太慢**
第一次没有缓存，之后 buildx GHA 缓存会显著加速。如果只改前端或只改后端，命中率会更高。

**Q: 磁盘满了**

```bash
docker system prune -af --volumes   # ⚠️ 会删掉未使用的卷，先确认
du -sh /opt/sub2api/backups
```

**Q: 从上游 `Wei-Shaw/sub2api` 合并更新后 workflow 冲突**
`azure-deploy.yml` 和 `deploy/azure/` 都是本仓库新增的文件，上游不会有同名文件，正常情况下不冲突。但 `deploy/docker-compose.yml` 上游会改动，合并后建议本地跑一次 `docker compose -f deploy/docker-compose.yml -f deploy/azure/docker-compose.azure.yml config` 确认没问题再推。

---

## 十、安全建议（按优先级）

1. **首次登录立刻改管理员密码**，并给管理员账号开 2FA。
2. **收紧 SSH 来源**：如果不用 GitHub 托管 runner，把 `AllowSSH` 规则的来源改成公司固定出口 IP。
3. **不要把 `.env` 提交到 Git**。它只应存在于 VM 上。仓库的 `.gitignore` 已忽略 `.env`，但 `deploy/azure/env.azure.example` 是模板，里面不要填真实密钥。
4. **打开 Azure Backup**，比只靠 pg_dump 更稳。
5. **定期更新**：cloud-init 已开启 `unattended-upgrades` 自动打安全补丁；VM 的 `patchMode` 设为 `AutomaticByPlatform`。
6. **考虑限制访问范围**：如果只给内部同事用，可以在 NSG 上把 443 的来源也限制为公司出口 IP。

---

## 十一、销毁全部资源

```bash
az group delete -n sub2api-rg --yes --no-wait
```

会删除该资源组下所有资源（VM、磁盘、IP、网络）。**数据不可恢复**，请先备份。
