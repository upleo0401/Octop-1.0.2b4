#!/usr/bin/env bash
# =============================================================================
# 清空公司 PostgreSQL 中的 Octop 业务表，重新走迁移（方案 A 必做）。
#
# 会删除 users / agents / 对话 / 知识库 等全部控制面数据，不可恢复。
# 不会删掉 Postgres 容器或 /home/octop-pgdata 数据目录。
#
# 服务器（root）：
#   bash /home/ops/reinit-postgres.sh --yes
#
# 之后：第一台 Windows 客户端连上该库并启动（或 octop init），会自动建表，
# 库里 0 个用户时走安装向导创建第一个管理员。
# =============================================================================
set -euo pipefail

export PATH="/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PG_USER="${OCTOP_PG_USER:-octop}"
PG_DB="${OCTOP_PG_DB:-octop}"
PG_NAME="${OCTOP_PG_CONTAINER:-octop-postgres}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ "${1:-}" = "--yes" ] || die "这会清空库 ${PG_DB}。确认后执行: bash $0 --yes"

command -v docker >/dev/null 2>&1 || die "找不到 docker"
docker inspect "$PG_NAME" >/dev/null 2>&1 || die "容器 ${PG_NAME} 不存在，先 bash /home/ops/install_postgres.sh"
docker start "$PG_NAME" >/dev/null

ok=0
i=0
while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    if docker exec "$PG_NAME" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        ok=1
        break
    fi
    sleep 2
done
[ "$ok" = 1 ] || die "PostgreSQL 未就绪。docker logs --tail 40 ${PG_NAME}"

echo "清空 ${PG_DB}.public …"
docker exec -i "$PG_NAME" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 <<'SQL'
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = current_database()
   AND pid <> pg_backend_pid();
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO PUBLIC;
CREATE EXTENSION IF NOT EXISTS vector;
SQL

echo
echo "=============================================="
echo "库已空。pgvector 扩展已就绪。Octop 表尚未创建。"
echo "请停掉 Linux 上的 Octop 应用容器（若还在跑）。"
echo "第一台 Windows 客户端配置："
echo "  OCTOP_DATABASE_DRIVER=postgresql"
echo "  OCTOP_DATABASE_URL=postgresql://${PG_USER}:****@<服务器IP>:5432/${PG_DB}"
echo "启动后自动迁移；打开向导创建第一个管理员。"
echo "=============================================="
