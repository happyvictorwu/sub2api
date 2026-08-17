#!/usr/bin/env bash
# =============================================================================
# 在 Azure VM 上执行的部署脚本（由 GitHub Actions 通过 SSH 管道送进来）
# =============================================================================
# 需要的环境变量（由 CI 在 ssh 命令行上注入）：
#   APP_IMAGE   完整镜像地址，例如 ghcr.io/xxx/sub2api:sha-abc1234
#   GHCR_USER   GHCR 用户名
#   GHCR_TOKEN  GHCR 令牌（CI 里用 GITHUB_TOKEN 即可）
# =============================================================================

set -euo pipefail

APP_DIR=/opt/slothwatching
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.azure.yml)

cd "${APP_DIR}"

if [[ ! -f .env ]]; then
  echo "::error:: ${APP_DIR}/.env 不存在，请先在本机运行 deploy/azure/bootstrap.sh" >&2
  exit 1
fi

echo "==> 登录 GHCR"
echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin

echo "==> 更新 .env 中的镜像标签 -> ${APP_IMAGE}"
if grep -q '^APP_IMAGE=' .env; then
  sed -i "s|^APP_IMAGE=.*|APP_IMAGE=${APP_IMAGE}|" .env
else
  printf '\nAPP_IMAGE=%s\n' "${APP_IMAGE}" >> .env
fi

echo "==> 备份数据库（保留最近 7 份）"
if docker ps --format '{{.Names}}' | grep -q '^slothwatching-postgres$'; then
  mkdir -p backups
  set +e
  # shellcheck disable=SC1091
  PGUSER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2-)"
  PGDB="$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2-)"
  BACKUP_FILE="backups/pre-deploy-$(date +%Y%m%d-%H%M%S).sql.gz"
  docker exec slothwatching-postgres pg_dump -U "${PGUSER:-slothwatching}" -d "${PGDB:-slothwatching}" \
    | gzip > "${BACKUP_FILE}"
  # pg_dump 失败时 gzip 仍会留下一个空壳文件，这里直接丢掉避免误以为有备份
  if [[ ! -s "${BACKUP_FILE}" ]] || [[ "$(stat -c %s "${BACKUP_FILE}")" -lt 200 ]]; then
    echo "    ⚠️  备份失败或内容为空，已删除 ${BACKUP_FILE}（不阻断部署）"
    rm -f "${BACKUP_FILE}"
  else
    echo "    备份完成: ${BACKUP_FILE} ($(du -h "${BACKUP_FILE}" | cut -f1))"
  fi
  set -e
  ls -1t backups/pre-deploy-*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
else
  echo "    (首次部署，跳过备份)"
fi

echo "==> 拉取镜像"
"${COMPOSE[@]}" pull

echo "==> 启动 / 更新服务"
"${COMPOSE[@]}" up -d --remove-orphans

echo "==> 等待应用健康检查通过"
HEALTHY=0
for i in $(seq 1 36); do
  STATUS="$(docker inspect --format '{{.State.Health.Status}}' slothwatching 2>/dev/null || echo unknown)"
  if [[ "${STATUS}" == "healthy" ]]; then
    HEALTHY=1
    break
  fi
  if [[ "${STATUS}" == "unknown" ]]; then
    echo "    容器尚未就绪..."
  else
    echo "    健康状态: ${STATUS} (${i}/36)"
  fi
  sleep 5
done

if [[ "${HEALTHY}" != "1" ]]; then
  echo "::error:: 应用未在 3 分钟内变为 healthy，最近日志如下：" >&2
  "${COMPOSE[@]}" logs --tail=120 slothwatching >&2 || true
  docker logout ghcr.io >/dev/null 2>&1 || true
  exit 1
fi

echo "==> 清理旧镜像"
docker image prune -af --filter "until=168h" >/dev/null || true

docker logout ghcr.io >/dev/null 2>&1 || true

echo "==> 当前服务状态"
"${COMPOSE[@]}" ps
echo "✅ 部署完成"
