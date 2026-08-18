#!/usr/bin/env bash
# =============================================================================
#  migrate-from-slothwatching.sh — 一次性迁移脚本，在 Azure VM 上执行
# =============================================================================
#
#  背景：仓库放弃了自有品牌，全量回退到上游 Sub2API 命名。VM 上这套部署是按
#  旧品牌建的，目录、容器、数据卷、数据库名全带 slothwatching 前缀，而
#  deploy/docker-compose.yml 回退后用的是 sub2api。两边对不上，CI 部署会失败。
#
#  这个脚本做四件事：
#    1. 停掉旧 compose 项目并删除它的数据卷（数据库会重建，站点尚无用户）
#    2. /opt/slothwatching -> /opt/sub2api，并把 .env 里的库名/用户名改掉
#    3. 清掉残留的 slothwatching 容器、数据卷和悬空镜像
#    4. 把 cloud-init 留下的 sysctl 配置文件改名（内容不变，避免丢设置）
#
#  幂等：已经迁移过就直接退出。跑完可以把本文件从仓库里删掉。
#
#  用法 A —— 从本机远程执行（推荐，不用先上传）：
#     ssh -i ~/.ssh/slothwatching_azure <user>@<vm-host> 'bash -s' \
#       < deploy/azure/migrate-from-slothwatching.sh
#
#  用法 B —— 已经登录到 VM 上：
#     bash migrate-from-slothwatching.sh
#
#  ⚠️  会删除数据库。确认没有需要保留的数据再跑。
# =============================================================================
set -euo pipefail

OLD_DIR=/opt/slothwatching
NEW_DIR=/opt/sub2api
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.azure.yml)

if [[ ! -d "${OLD_DIR}" ]]; then
  echo "✅ ${OLD_DIR} 不存在，无需迁移。"
  exit 0
fi

# 通过 `ssh ... 'bash -s'` 执行时没有 TTY，sudo 一旦要密码就会卡死在这里。
# 先探一下免密 sudo，探不到就明确报错而不是挂起。
if ! sudo -n true 2>/dev/null; then
  echo "❌ 需要免密 sudo（脚本要移动 /opt 下的目录）。" >&2
  echo "   请先 ssh 登录到 VM，再在上面直接执行本脚本。" >&2
  exit 1
fi

echo "==> 1/4 停止旧 compose 项目并删除其数据卷"
if cd "${OLD_DIR}" && [[ -f docker-compose.yml ]]; then
  # 项目名取自目录名（slothwatching），所以这里删掉的是旧前缀的那组卷
  "${COMPOSE[@]}" down -v --remove-orphans || echo "    (compose down 失败，继续按名字清理)"
fi

echo "==> 2/4 迁移目录到 ${NEW_DIR}"
cd /
sudo mv "${OLD_DIR}" "${NEW_DIR}"
sudo chown -R "$(id -u):$(id -g)" "${NEW_DIR}"
# 旧备份是旧 schema 的，留着没用
rm -rf "${NEW_DIR}/backups"
sed -i 's/^POSTGRES_USER=.*/POSTGRES_USER=sub2api/; s/^POSTGRES_DB=.*/POSTGRES_DB=sub2api/' "${NEW_DIR}/.env"
echo "    .env 已更新：$(grep -E '^POSTGRES_(USER|DB)=' "${NEW_DIR}/.env" | tr '\n' ' ')"

echo "==> 3/4 清理残留容器 / 数据卷 / 悬空镜像"
docker ps -aq --filter 'name=^slothwatching' | xargs -r docker rm -f
docker volume ls -q --filter 'name=^slothwatching' | xargs -r docker volume rm
docker image prune -f >/dev/null
echo "    剩余 slothwatching 相关对象：$(( $(docker ps -aq --filter 'name=^slothwatching' | wc -l) + $(docker volume ls -q --filter 'name=^slothwatching' | wc -l) )) 个"

echo "==> 4/4 处理 cloud-init 留下的 sysctl 文件"
if [[ -f /etc/sysctl.d/99-slothwatching.conf ]]; then
  # 内容与新版一致，改名而不是删除，避免丢掉已生效的内核参数
  sudo mv /etc/sysctl.d/99-slothwatching.conf /etc/sysctl.d/99-sub2api.conf
  echo "    已改名为 99-sub2api.conf"
else
  echo "    (无)"
fi

echo
echo "✅ 迁移完成。接下来 push 到 main，CI 会自动部署到 ${NEW_DIR}。"
echo "   注意：Caddy 的证书卷已被删除，首次部署会重新签发，健康检查可能需要 1-2 分钟。"
