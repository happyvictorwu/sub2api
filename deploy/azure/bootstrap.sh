#!/usr/bin/env bash
# =============================================================================
# Sub2API on Azure - 一次性初始化脚本
# =============================================================================
# 在你自己的电脑上运行（需要已安装并登录 Azure CLI：az login）。
# 它会：
#   1. 创建资源组和虚拟机（Bicep）
#   2. 等待 cloud-init 装好 Docker
#   3. 生成随机密钥并把 .env 写到 VM 的 /opt/sub2api/
#   4. 打印需要配置到 GitHub 的 Secrets
#
# 用法：
#   cd deploy/azure
#   ./bootstrap.sh
#
# 可用环境变量覆盖默认值，例如：
#   LOCATION=eastasia VM_SIZE=Standard_B2ms ./bootstrap.sh
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-sub2api-rg}"
LOCATION="${LOCATION:-southeastasia}"
NAME_PREFIX="${NAME_PREFIX:-sub2api}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"
OS_DISK_SIZE_GB="${OS_DISK_SIZE_GB:-64}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/sub2api_azure}"
SSH_ALLOWED_CIDR="${SSH_ALLOWED_CIDR:-*}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/happyvictorwu/sub2api:latest}"
TIMEZONE="${TIMEZONE:-Asia/Singapore}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "未找到 az，请先安装 Azure CLI：https://learn.microsoft.com/cli/azure/install-azure-cli"
command -v openssl >/dev/null || die "未找到 openssl"
az account show >/dev/null 2>&1 || die "尚未登录 Azure，请先执行：az login"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
SUBSCRIPTION_NAME="$(az account show --query name -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
# 幂等：已存在的公网 IP 优先复用其 DNS 标签，避免重跑时换域名
EXISTING_LABEL="$(az network public-ip show -g "${RESOURCE_GROUP}" -n "${NAME_PREFIX}-pip" \
  --query dnsSettings.domainNameLabel -o tsv 2>/dev/null || true)"
DNS_LABEL="${DNS_LABEL:-${EXISTING_LABEL:-${NAME_PREFIX}-$(openssl rand -hex 3)}}"

info "订阅        : ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"
info "资源组      : ${RESOURCE_GROUP}"
info "区域        : ${LOCATION}"
info "VM 规格     : ${VM_SIZE}"
info "DNS 标签    : ${DNS_LABEL}"
echo

# -----------------------------------------------------------------------------
# 1. SSH 密钥
# -----------------------------------------------------------------------------
if [[ ! -f "${SSH_KEY}" ]]; then
  info "生成 SSH 密钥：${SSH_KEY}"
  ssh-keygen -t ed25519 -N '' -C "sub2api-azure-deploy" -f "${SSH_KEY}" >/dev/null
  ok "SSH 密钥已生成"
else
  info "复用已有 SSH 密钥：${SSH_KEY}"
fi

# -----------------------------------------------------------------------------
# 2. 创建资源组 + 部署 VM
# -----------------------------------------------------------------------------
info "创建资源组..."
az group create -n "${RESOURCE_GROUP}" -l "${LOCATION}" -o none

# 幂等：VM 已存在就跳过部署。Azure 禁止修改已存在 VM 的 osProfile.customData，
# 重跑 Bicep 会直接报 PropertyChangeNotAllowed。要应用新的 cloud-init 必须删 VM 重建。
if az vm show -g "${RESOURCE_GROUP}" -n "${NAME_PREFIX}-vm" -o none 2>/dev/null; then
  warn "检测到 ${NAME_PREFIX}-vm 已存在，跳过基础设施部署"
  warn "（如需应用新的 cloud-init，须先删除 VM：az vm delete -g ${RESOURCE_GROUP} -n ${NAME_PREFIX}-vm --yes）"
  FQDN="$(az network public-ip show -g "${RESOURCE_GROUP}" -n "${NAME_PREFIX}-pip" --query dnsSettings.fqdn -o tsv)"
  PUBLIC_IP="$(az network public-ip show -g "${RESOURCE_GROUP}" -n "${NAME_PREFIX}-pip" --query ipAddress -o tsv)"
  ok "复用已有 VM：${FQDN} (${PUBLIC_IP})"
else

info "部署虚拟机（首次约需 2-4 分钟）..."
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "sub2api-infra" \
  --template-file "${SCRIPT_DIR}/main.bicep" \
  --parameters \
      namePrefix="${NAME_PREFIX}" \
      dnsLabel="${DNS_LABEL}" \
      adminUsername="${ADMIN_USERNAME}" \
      adminSshPublicKey="$(cat "${SSH_KEY}.pub")" \
      vmSize="${VM_SIZE}" \
      osDiskSizeGb="${OS_DISK_SIZE_GB}" \
      sshSourceAddressPrefix="${SSH_ALLOWED_CIDR}" \
  -o none

FQDN="$(az deployment group show -g "${RESOURCE_GROUP}" -n sub2api-infra --query properties.outputs.fqdn.value -o tsv)"
PUBLIC_IP="$(az deployment group show -g "${RESOURCE_GROUP}" -n sub2api-infra --query properties.outputs.publicIp.value -o tsv)"
ok "VM 就绪：${FQDN} (${PUBLIC_IP})"

fi

SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=10)

# -----------------------------------------------------------------------------
# 3. 等待 cloud-init 装好 Docker
# -----------------------------------------------------------------------------
info "等待 cloud-init 完成（安装 Docker，约 2-5 分钟）..."
for i in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" "${ADMIN_USERNAME}@${FQDN}" 'test -f /opt/sub2api/.cloud-init-done' 2>/dev/null; then
    ok "cloud-init 完成"
    break
  fi
  [[ $i -eq 60 ]] && die "等待超时。请手动登录检查：ssh -i ${SSH_KEY} ${ADMIN_USERNAME}@${FQDN} 然后看 /var/log/cloud-init-output.log"
  sleep 15
done

# -----------------------------------------------------------------------------
# 4. 生成 .env 并上传（已存在则不覆盖，避免冲掉线上密钥）
# -----------------------------------------------------------------------------
if ssh "${SSH_OPTS[@]}" "${ADMIN_USERNAME}@${FQDN}" 'test -f /opt/sub2api/.env'; then
  warn "VM 上已存在 /opt/sub2api/.env，跳过生成（如需重建请先手动备份删除）"
else
  info "生成随机密钥并写入 VM..."
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  REDIS_PASSWORD="$(openssl rand -hex 24)"
  JWT_SECRET="$(openssl rand -hex 32)"
  TOTP_ENCRYPTION_KEY="$(openssl rand -hex 32)"
  ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)"

  TMP_ENV="$(mktemp)"
  trap 'rm -f "${TMP_ENV}"' EXIT
  sed \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=${APP_IMAGE}|" \
    -e "s|^SITE_ADDRESS=.*|SITE_ADDRESS=${FQDN}|" \
    -e "s|^SITE_URL=.*|SITE_URL=https://${FQDN}|" \
    -e "s|^ACME_EMAIL=.*|ACME_EMAIL=${ADMIN_EMAIL}|" \
    -e "s|^TZ=.*|TZ=${TIMEZONE}|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" \
    -e "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASSWORD}|" \
    -e "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" \
    -e "s|^TOTP_ENCRYPTION_KEY=.*|TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY}|" \
    -e "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=${ADMIN_EMAIL}|" \
    -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|" \
    "${SCRIPT_DIR}/env.azure.example" > "${TMP_ENV}"

  scp "${SSH_OPTS[@]}" "${TMP_ENV}" "${ADMIN_USERNAME}@${FQDN}:/opt/sub2api/.env" >/dev/null
  ssh "${SSH_OPTS[@]}" "${ADMIN_USERNAME}@${FQDN}" 'chmod 600 /opt/sub2api/.env'
  ok ".env 已写入 VM"

  echo
  echo "================= 请立刻保存以下管理员凭据 ================="
  echo "  登录地址 : https://${FQDN}"
  echo "  管理员   : ${ADMIN_EMAIL}"
  echo "  初始密码 : ${ADMIN_PASSWORD}"
  echo "==========================================================="
fi

# -----------------------------------------------------------------------------
# 5. 输出 GitHub Secrets
# -----------------------------------------------------------------------------
echo
ok "基础设施就绪。接下来在 GitHub 仓库配置 Secrets："
echo
echo "  Settings → Secrets and variables → Actions → New repository secret"
echo
echo "  AZURE_VM_HOST     = ${FQDN}"
echo "  AZURE_VM_USER     = ${ADMIN_USERNAME}"
echo "  AZURE_VM_SSH_KEY  = （下面这段私钥的完整内容，含首尾 BEGIN/END 行）"
echo
echo "-------------------------------------------------------------"
cat "${SSH_KEY}"
echo "-------------------------------------------------------------"
echo
if command -v gh >/dev/null 2>&1; then
  echo "已检测到 gh CLI，可以直接执行："
  echo "  gh secret set AZURE_VM_HOST    --body '${FQDN}'"
  echo "  gh secret set AZURE_VM_USER    --body '${ADMIN_USERNAME}'"
  echo "  gh secret set AZURE_VM_SSH_KEY < ${SSH_KEY}"
  echo
fi
echo "配置完成后，push 到 main 分支或在 Actions 里手动运行 'Deploy to Azure' 即可完成首次部署。"
echo
echo "参考信息："
echo "  订阅 ID  : ${SUBSCRIPTION_ID}"
echo "  租户 ID  : ${TENANT_ID}"
echo "  SSH 登录 : ssh -i ${SSH_KEY} ${ADMIN_USERNAME}@${FQDN}"
