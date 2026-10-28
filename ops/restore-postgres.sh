#!/usr/bin/env bash
# =============================================================================
# 把 Octop 应用容器改回「原来的」PostgreSQL
#
# 只重建 octop 应用容器。不会：
#   - 删除 / 重建 octop-postgres
#   - 换数据目录（固定 /home/octop-pgdata）
#   - 删除 /home/octop-data/.octop
#
# 服务器（root）：
#   bash /home/ops/restore-postgres.sh
# =============================================================================
set -euo pipefail

export PATH="/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DATA_DIR="${OCTOP_DATA_DIR:-/home/octop-data/.octop}"
PG_DATA="${OCTOP_PG_DATA:-/home/octop-pgdata}"
NAME="${OCTOP_CONTAINER:-octop}"
PG_NAME="${OCTOP_PG_CONTAINER:-octop-postgres}"
NET="${OCTOP_DOCKER_NET:-octop-net}"
PORT="${OCTOP_PORT:-8088}"
PG_USER="${OCTOP_PG_USER:-octop}"
PG_PASSWORD="${OCTOP_PG_PASSWORD:-octop}"
PG_DB="${OCTOP_PG_DB:-octop}"
PG_URL="postgresql://${PG_USER}:${PG_PASSWORD}@${PG_NAME}:5432/${PG_DB}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

pg_counts() {
    docker exec "$PG_NAME" psql -U "$PG_USER" -d "$PG_DB" -At -c \
        "SELECT 'users='||(SELECT count(*) FROM users)||' agents='||(SELECT count(*) FROM agents)||' knowledge_bases='||(SELECT count(*) FROM knowledge_bases);" \
        2>/dev/null || echo "(查不到表或库未就绪)"
}

[ "$(id -u)" = "0" ] || die "请用 root 执行"
command -v docker >/dev/null 2>&1 || die "找不到 docker（确认 PATH 含 /home/bin）"
[ -d "$DATA_DIR" ] || die "数据目录不存在: $DATA_DIR"
[ -f "${PG_DATA}/PG_VERSION" ] || die "找不到原 Postgres 数据目录 ${PG_DATA}/PG_VERSION，拒绝连空库"

IMAGE="$(docker inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null || true)"
IMAGE="${IMAGE:-${OCTOP_IMAGE:-octop:local}}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "没有镜像 ${IMAGE}"

echo "=============================================="
echo "改回原来的 PostgreSQL（不新建空库）"
echo "PG 容器: ${PG_NAME}"
echo "PG 数据: ${PG_DATA}"
echo "应用:    ${NAME}  镜像=${IMAGE}"
echo "=============================================="

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

if docker ps -a --format '{{.Names}}' | grep -qx "$PG_NAME"; then
    echo "启动已有 ${PG_NAME}（不删除）"
    docker start "$PG_NAME" >/dev/null
else
    echo "容器 ${PG_NAME} 不在，用原目录 ${PG_DATA} 挂回去（不是新库）"
    PG_IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'pgvector|postgres' | head -n1 || true)"
    PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:pg16}"
    docker run -d \
        --name "$PG_NAME" \
        --restart unless-stopped \
        --network "$NET" \
        -p 5432:5432 \
        -e POSTGRES_USER="$PG_USER" \
        -e POSTGRES_PASSWORD="$PG_PASSWORD" \
        -e POSTGRES_DB="$PG_DB" \
        -v "${PG_DATA}:/var/lib/postgresql/data" \
        "$PG_IMAGE"
fi
docker network connect "$NET" "$PG_NAME" 2>/dev/null || true

ok=0
for i in $(seq 1 40); do
    if docker exec "$PG_NAME" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        ok=1
        break
    fi
    sleep 2
done
[ "$ok" = "1" ] || die "PostgreSQL 未就绪。docker logs --tail 40 ${PG_NAME}"

echo
echo "---- 原 PostgreSQL 行数 ----"
pg_counts

echo
echo "---- 写入 config.json → 同一套 postgres ----"
docker run --rm -v "${DATA_DIR}:/data/.octop" -e HOME=/data "$IMAGE" python -c "
from pathlib import Path
import json
p = Path('/data/.octop/config.json')
cfg = {}
if p.is_file():
    try:
        cfg = json.loads(p.read_text(encoding='utf-8'))
    except Exception:
        cfg = {}
if not isinstance(cfg, dict):
    cfg = {}
cfg['database'] = {
    'driver': 'postgresql',
    'host': '${PG_NAME}',
    'port': 5432,
    'database': '${PG_DB}',
    'user': '${PG_USER}',
    'password': '${PG_PASSWORD}',
}
p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + chr(10), encoding='utf-8')
print(cfg.get('database'))
"

echo
echo "---- 只重建应用容器 octop（不加新 postgres）----"
docker rm -f "$NAME" 2>/dev/null || true
docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    --network "$NET" \
    -p "${PORT}:${PORT}" \
    -v "${DATA_DIR}:/data/.octop" \
    -e HOME=/data \
    -e OCTOP_BIND_HOST=0.0.0.0 \
    -e OCTOP_PORT="$PORT" \
    -e OCTOP_DATABASE_DRIVER=postgresql \
    -e OCTOP_DATABASE_URL="$PG_URL" \
    -e OCTOP_DATABASE_HOST="$PG_NAME" \
    -e OCTOP_DATABASE_PORT=5432 \
    -e OCTOP_DATABASE_NAME="$PG_DB" \
    -e OCTOP_DATABASE_USER="$PG_USER" \
    -e OCTOP_DATABASE_PASSWORD="$PG_PASSWORD" \
    "$IMAGE"

health="000"
for i in $(seq 1 40); do
    health="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
        "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || echo 000)"
    echo "  $(date +%T) health=${health}"
    if [ "$health" = "200" ]; then
        break
    fi
    sleep 3
done

echo
echo "---- 容器内 config ----"
docker exec "$NAME" python -c "import json; print(json.load(open('/data/.octop/config.json')).get('database'))"
echo "---- PostgreSQL 行数（应与上面一致）----"
pg_counts

[ "$health" = "200" ] || die "仍未就绪 health=${health}。docker logs --tail 80 ${NAME}"
echo
echo "完成。刷新客户端（不必重装）。"
echo "若 knowledge_bases/agents 仍是 0，说明原来的 PG 里就是空的，数据可能只在 octop.db，不要再切来切去，把查询结果发回来。"
