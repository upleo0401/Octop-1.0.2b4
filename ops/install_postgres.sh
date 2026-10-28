#!/usr/bin/env bash
# =============================================================================
# Docker 部署 Octop 用 PostgreSQL（pgvector/pg16）
# 对应 docker/docker-compose.postgres.yml，给没有 compose 的静态 Docker 用。
#
# 传到服务器后执行（root，不要加参数）：
#   bash /home/ops/install_postgres.sh
#
# 数据：/home/octop-pgdata
# 默认账号：octop / octop    库名：octop    端口：5432
# =============================================================================
PG_USER="${OCTOP_PG_USER:-octop}"
PG_PASSWORD="${OCTOP_PG_PASSWORD:-octop}"
PG_DB="${OCTOP_PG_DB:-octop}"
PG_PORT="${OCTOP_PG_PORT:-5432}"
PG_NAME="${OCTOP_PG_CONTAINER:-octop-postgres}"
PG_DATA="${OCTOP_PG_DATA:-/home/octop-pgdata}"
SRC="${OCTOP_SRC:-/home/Octop-1.0.2b4}"
OCTOP_NAME="${OCTOP_CONTAINER:-octop}"
IMAGE_OFFICIAL="pgvector/pgvector:pg16"
IMAGE_MIRROR="docker.m.daocloud.io/pgvector/pgvector:pg16"

set -e
export PATH="/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==== %s ====\n' "$*"; }

command -v docker >/dev/null 2>&1 || die "找不到 docker，先 export PATH=/home/bin:\$PATH"
docker info >/dev/null 2>&1 || die "dockerd 未运行，先 bash /home/octop.sh"

INIT_SQL="$SRC/docker/postgres/init-vector.sql"
[ -f "$INIT_SQL" ] || die "找不到 $INIT_SQL"

mkdir -p "$PG_DATA"

pull_image() {
    if docker image inspect "$IMAGE_OFFICIAL" >/dev/null 2>&1; then
        echo "已有镜像 $IMAGE_OFFICIAL"
        return 0
    fi
    log "拉取 $IMAGE_MIRROR"
    if docker pull "$IMAGE_MIRROR"; then
        docker tag "$IMAGE_MIRROR" "$IMAGE_OFFICIAL"
        return 0
    fi
    log "镜像站失败，改拉 $IMAGE_OFFICIAL"
    docker pull "$IMAGE_OFFICIAL"
}

pull_image

if docker ps -a --format '{{.Names}}' | grep -qx "$PG_NAME"; then
    log "容器 $PG_NAME 已存在，启动它"
    docker start "$PG_NAME" >/dev/null
else
    log "创建 $PG_NAME"
    docker run -d \
        --name "$PG_NAME" \
        --restart unless-stopped \
        -p "${PG_PORT}:5432" \
        -e POSTGRES_USER="$PG_USER" \
        -e POSTGRES_PASSWORD="$PG_PASSWORD" \
        -e POSTGRES_DB="$PG_DB" \
        -v "${PG_DATA}:/var/lib/postgresql/data" \
        -v "${INIT_SQL}:/docker-entrypoint-initdb.d/01-vector.sql:ro" \
        "$IMAGE_OFFICIAL"
fi

log "等待 postgres 就绪"
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
[ "$ok" = 1 ] || {
    docker logs --tail 40 "$PG_NAME" || true
    die "PostgreSQL 未能就绪"
}

if docker ps --format '{{.Names}}' | grep -qx "$OCTOP_NAME"; then
    docker network connect bridge "$PG_NAME" 2>/dev/null || true
fi

DSN_HOST="postgresql://${PG_USER}:${PG_PASSWORD}@172.17.0.1:${PG_PORT}/${PG_DB}"
echo
echo "=============================================="
echo "PostgreSQL 已启动  容器=${PG_NAME}  数据=${PG_DATA}"
echo "本机:     postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_PORT}/${PG_DB}"
echo "Octop容器请填主机: 172.17.0.1"
echo "DSN:      ${DSN_HOST}"
echo
echo "Octop 网页设置向导 → 展开更多 → PostgreSQL："
echo "  主机 ${PG_USER}  端口 ${PG_PORT}  库名 ${PG_DB}"
echo "  用户 ${PG_USER}  密码 ${PG_PASSWORD}"
echo "或给 Octop 容器增加："
echo "  OCTOP_DATABASE_DRIVER=postgresql"
echo "  OCTOP_DATABASE_URL=${DSN_HOST}"
echo
echo "已有 SQLite 数据不会自动迁移；换引擎后不能和 SQLite 备份互恢。"
echo "方案 A 换 Windows 完整客户端时请清空旧库："
echo "  bash /home/ops/reinit-postgres.sh --yes"
echo "=============================================="
