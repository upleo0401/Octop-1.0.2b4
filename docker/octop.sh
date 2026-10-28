#!/usr/bin/env bash
# =============================================================================
# CentOS 7 / 静态 Docker：唯一入口脚本（安装 + 拉起 + 放行端口 已合并）
#
# 服务器上执行（root）：
#   bash /home/octop.sh
#
# 无参数：没有镜像就构建，然后补 desktop、关防火墙、启动并等到 health=200。
#   bash /home/octop.sh up        # 不构建，只拉起（会重建容器以挂上 PostgreSQL）
#   bash /home/octop.sh install   # 强制重新构建镜像再拉起
#   bash /home/octop.sh rebuild   # 同 install（不删 /home/octop-data/.octop 与 Postgres 数据）
# 只替换应用容器；数据在宿主机目录，不会随 docker rm 丢失。
#
# 默认控制面：PostgreSQL（容器 octop-postgres）。已有 SQLite 用户不会自动迁移。
# =============================================================================
set -euo pipefail

export PATH="/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${OCTOP_SRC:-/home/Octop-1.0.2b4}"
IMAGE_TAG="${OCTOP_IMAGE:-octop:local}"
DATA_DIR="${OCTOP_DATA_DIR:-/home/octop-data/.octop}"
DOCKER_DATA="${DOCKER_DATA_ROOT:-/home/docker-data}"
PORT="${OCTOP_PORT:-8088}"
NAME="${OCTOP_CONTAINER:-octop}"
BUILDX_VER="v0.16.2"
CMD="${1:-auto}"

PG_USER="${OCTOP_PG_USER:-octop}"
PG_PASSWORD="${OCTOP_PG_PASSWORD:-octop}"
PG_DB="${OCTOP_PG_DB:-octop}"
PG_PORT="${OCTOP_PG_PORT:-5432}"
PG_NAME="${OCTOP_PG_CONTAINER:-octop-postgres}"
PG_DATA="${OCTOP_PG_DATA:-/home/octop-pgdata}"
NET="${OCTOP_DOCKER_NET:-octop-net}"
PG_IMAGE_OFFICIAL="pgvector/pgvector:pg16"
PG_IMAGE_MIRROR="docker.m.daocloud.io/pgvector/pgvector:pg16"
PG_URL="postgresql://${PG_USER}:${PG_PASSWORD}@${PG_NAME}:5432/${PG_DB}"

log() { printf '\n==== %s ====\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "找不到命令 $1（把静态 docker 放到 /home/bin）"
}

download() {
    local dest="$1"; shift
    local url
    for url in "$@"; do
        echo "尝试下载: $url"
        if curl -fL --retry 3 --connect-timeout 25 --max-time 180 -o "$dest" "$url"; then
            [ -s "$dest" ] && return 0
        fi
        rm -f "$dest"
    done
    return 1
}

lan_ip() {
    ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

ensure_dockerd() {
    mkdir -p /etc/docker "$DOCKER_DATA" "$DATA_DIR" /root/.docker/cli-plugins
    if [ ! -f /etc/docker/daemon.json ]; then
        cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${DOCKER_DATA}",
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run"
  ]
}
EOF
    fi
    if docker info >/dev/null 2>&1; then
        echo "dockerd 已在运行"
        return 0
    fi
    log "启动 dockerd（data-root 只写在 daemon.json）"
    nohup dockerd >/home/dockerd.log 2>&1 &
    local i ok=0
    for i in $(seq 1 40); do
        if docker info >/dev/null 2>&1; then ok=1; break; fi
        sleep 1
    done
    [ "$ok" = 1 ] || { tail -n 40 /home/dockerd.log || true; die "dockerd 未能启动，看 /home/dockerd.log"; }
}

open_firewall() {
    log "关闭 firewalld 并放行 ${PORT}"
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "${PORT}" -j ACCEPT
    iptables -C FORWARD -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -p tcp --dport "${PORT}" -j ACCEPT
    iptables -C FORWARD -i docker0 -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i docker0 -j ACCEPT
    iptables -C FORWARD -o docker0 -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -o docker0 -j ACCEPT
}

sync_desktop_into_tree() {
    mkdir -p "$SRC/src/octop/api/routers" "$SRC/src/octop/infra"
    if [ -f "$SRC/src/octop/api/routers/desktop/__init__.py" ] \
        && [ -f "$SRC/src/octop/infra/desktop/__init__.py" ]; then
        echo "源码树已有 desktop 包"
        return 0
    fi
    local bundle
    for bundle in \
        "$HERE/bundled-desktop.tar.gz" \
        /home/bundled-desktop.tar.gz \
        "$SRC/docker/bundled-desktop.tar.gz"
    do
        [ -f "$bundle" ] || continue
        log "解开 $bundle"
        tar -xzf "$bundle" -C "$SRC/src/octop"
        return 0
    done
    die "缺少 desktop 包。请上传 /home/bundled-desktop.tar.gz（Windows: docker/bundled-desktop.tar.gz）"
}

sync_desktop_into_container() {
    docker exec "$NAME" mkdir -p /app/src/octop/api/routers/desktop /app/src/octop/infra/desktop
    docker cp "$SRC/src/octop/api/routers/desktop/." "$NAME":/app/src/octop/api/routers/desktop/
    docker cp "$SRC/src/octop/infra/desktop/." "$NAME":/app/src/octop/infra/desktop/
}

ensure_network() {
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
}

pull_pg_image() {
    if docker image inspect "$PG_IMAGE_OFFICIAL" >/dev/null 2>&1; then
        echo "已有镜像 $PG_IMAGE_OFFICIAL"
        return 0
    fi
    log "拉取 $PG_IMAGE_MIRROR"
    if docker pull "$PG_IMAGE_MIRROR"; then
        docker tag "$PG_IMAGE_MIRROR" "$PG_IMAGE_OFFICIAL"
        return 0
    fi
    log "镜像站失败，改拉 $PG_IMAGE_OFFICIAL"
    docker pull "$PG_IMAGE_OFFICIAL"
}

ensure_postgres() {
    local init_sql="$SRC/docker/postgres/init-vector.sql"
    [ -f "$init_sql" ] || die "找不到 $init_sql"
    mkdir -p "$PG_DATA"
    ensure_network
    pull_pg_image
    if docker ps -a --format '{{.Names}}' | grep -qx "$PG_NAME"; then
        log "复用已有 PostgreSQL 容器 ${PG_NAME}（不删、不换数据目录）"
        docker start "$PG_NAME" >/dev/null
    elif [ -f "${PG_DATA}/PG_VERSION" ]; then
        log "容器 ${PG_NAME} 不在，用原数据目录重建容器: ${PG_DATA}"
        docker run -d \
            --name "$PG_NAME" \
            --restart unless-stopped \
            --network "$NET" \
            -p "${PG_PORT}:5432" \
            -e POSTGRES_USER="$PG_USER" \
            -e POSTGRES_PASSWORD="$PG_PASSWORD" \
            -e POSTGRES_DB="$PG_DB" \
            -v "${PG_DATA}:/var/lib/postgresql/data" \
            "$PG_IMAGE_OFFICIAL"
    else
        [ "${OCTOP_ALLOW_NEW_POSTGRES:-0}" = "1" ] || die \
            "拒绝创建空 PostgreSQL：${PG_DATA} 没有 PG_VERSION。这会连上新空库。确认未删 ${PG_DATA}，或首次装库时加 OCTOP_ALLOW_NEW_POSTGRES=1"
        log "首次创建 PostgreSQL（数据目录为空） ${PG_DATA}"
        docker run -d \
            --name "$PG_NAME" \
            --restart unless-stopped \
            --network "$NET" \
            -p "${PG_PORT}:5432" \
            -e POSTGRES_USER="$PG_USER" \
            -e POSTGRES_PASSWORD="$PG_PASSWORD" \
            -e POSTGRES_DB="$PG_DB" \
            -v "${PG_DATA}:/var/lib/postgresql/data" \
            -v "${init_sql}:/docker-entrypoint-initdb.d/01-vector.sql:ro" \
            "$PG_IMAGE_OFFICIAL"
    fi
    docker network connect "$NET" "$PG_NAME" 2>/dev/null || true
    log "等待 postgres 就绪"
    local i ok=0
    for i in $(seq 1 40); do
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
}

sideline_history_v2() {
    if [ -f "$DATA_DIR/history_v2.sqlite" ]; then
        log "PostgreSQL 不支持 history_v2，已改名为 history_v2.sqlite.sqlite-bak"
        mv -f "$DATA_DIR/history_v2.sqlite" "$DATA_DIR/history_v2.sqlite.sqlite-bak"
    fi
    rm -f "$DATA_DIR/history_v2.required"
}

write_pg_config() {
    docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || return 0
    docker run --rm \
        -v "${DATA_DIR}:/data/.octop" \
        -e HOME=/data \
        "$IMAGE_TAG" \
        python -c "
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
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + chr(10), encoding='utf-8')
print('config.json database.driver=postgresql')
"
}

ensure_container() {
    mkdir -p "$DATA_DIR"
    docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 \
        || die "没有镜像 ${IMAGE_TAG}，请执行: bash /home/octop.sh install"
    docker rm -f "$NAME" 2>/dev/null || true
    ensure_network
    ensure_postgres
    sideline_history_v2
    write_pg_config
    log "重建 Octop 容器（默认 PostgreSQL）"
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
        "$IMAGE_TAG"
}

wait_health() {
    local i health="000"
    log "等待 /api/health == 200（最多约 120 秒）"
    for i in $(seq 1 40); do
        health="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 5 \
            "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || echo 000)"
        echo "  $(date +%T) health=${health}"
        if [ "$health" = "200" ]; then
            return 0
        fi
        sleep 3
    done
    echo "---- docker logs ----"
    docker logs --tail 50 "$NAME" 2>&1 || true
    return 1
}

print_result() {
    local health="$1"
    local ip
    ip="$(lan_ip)"
    ip="${ip:-192.168.3.61}"
    echo
    echo "=============================================="
    if [ "$health" = "200" ]; then
        echo "Octop 已启动  health=200"
    else
        echo "仍未就绪 health=${health}。看: docker logs --tail 80 ${NAME}"
    fi
    echo "浏览器: http://${ip}:${PORT}   （必须 http）"
    echo "EXE 公司服务器地址: http://${ip}:${PORT}"
    echo "控制面数据库: PostgreSQL  ${PG_NAME}  库=${PG_DB}  用户=${PG_USER}"
    echo "SQLite 旧数据不会迁过去；空库会再走一次安装向导（选 PostgreSQL）。"
    echo "=============================================="
    docker exec "$NAME" cat /data/.octop/credential.txt 2>/dev/null || true
}

patch_dockerfile() {
    local df="$SRC/docker/Dockerfile"
    [ -f "$df" ] || die "找不到 $df"
    cp -a "$df" "$df.bak.oneclick" 2>/dev/null || true
    sed -i '/^# syntax=docker\/dockerfile:/d' "$df"
    grep -qE '^FROM node:' "$df" && sed -i 's|^FROM node:|FROM docker.m.daocloud.io/library/node:|' "$df" || true
    grep -qE '^FROM python:' "$df" && sed -i 's|^FROM python:|FROM docker.m.daocloud.io/library/python:|' "$df" || true
    if grep -q 'COPY --from=.*astral-sh/uv' "$df"; then
        sed -i '/COPY --from=.*astral-sh\/uv/c\RUN pip install -i https://mirrors.cloud.tencent.com/pypi/simple --trusted-host mirrors.cloud.tencent.com "uv==0.7.21"' "$df"
    fi
}

ensure_buildx() {
    if docker buildx version >/dev/null 2>&1; then
        docker buildx version
        return 0
    fi
    local bx="/home/docker-buildx"
    if download "$bx" \
        "https://ghfast.top/https://github.com/docker/buildx/releases/download/${BUILDX_VER}/buildx-${BUILDX_VER}.linux-amd64" \
        "https://github.com/docker/buildx/releases/download/${BUILDX_VER}/buildx-${BUILDX_VER}.linux-amd64"
    then
        cp "$bx" /root/.docker/cli-plugins/docker-buildx
        chmod +x /root/.docker/cli-plugins/docker-buildx
        docker buildx version >/dev/null 2>&1 && return 0
    fi
    log "无 buildx，去掉 --mount"
    awk '/RUN --mount/ { sub(/RUN --mount[^\n]*/, "RUN") } /--mount=type=cache/ { next } { print }' \
        "$SRC/docker/Dockerfile" > "$SRC/docker/Dockerfile.tmp.oneclick"
    mv "$SRC/docker/Dockerfile.tmp.oneclick" "$SRC/docker/Dockerfile"
    sed -i 's/export DOCKER_BUILDKIT=1/export DOCKER_BUILDKIT=0/' "$SRC/docker/docker_build.sh"
}

do_install() {
    need_bin docker
    need_bin dockerd
    need_bin curl
    [ -d "$SRC" ] || die "源码目录不存在: $SRC"
    sync_desktop_into_tree
    ensure_dockerd
    ensure_buildx
    patch_dockerfile
    log "构建镜像 ${IMAGE_TAG}（最久，不要中断）"
    export PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.cloud.tencent.com/pypi/simple}"
    export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-mirrors.cloud.tencent.com}"
    export NPM_REGISTRY="${NPM_REGISTRY:-https://mirrors.cloud.tencent.com/npm/}"
    export APT_MIRROR="${APT_MIRROR:-mirrors.cloud.tencent.com}"
    export NODE_MAX_OLD_SPACE_SIZE="${NODE_MAX_OLD_SPACE_SIZE:-4096}"
    cd "$SRC"
    bash docker/docker_build.sh "$IMAGE_TAG"
    docker rm -f "$NAME" 2>/dev/null || true
}

do_up() {
    need_bin docker
    need_bin dockerd
    need_bin curl
    sync_desktop_into_tree
    ensure_dockerd
    open_firewall
    ensure_container
    sync_desktop_into_container
    docker restart "$NAME"
    local health="000"
    if wait_health; then
        health="200"
    else
        health="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
            "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || echo 000)"
    fi
    print_result "$health"
    [ "$health" = "200" ]
}

need_bin docker
need_bin dockerd

case "$CMD" in
    install|rebuild)
        do_install
        do_up
        ;;
    up)
        do_up
        ;;
    auto|"")
        if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
            log "已有镜像 ${IMAGE_TAG}，只拉起（构建请: bash /home/octop.sh install）"
            do_up
        else
            do_install
            do_up
        fi
        ;;
    *)
        die "未知参数: $CMD  （可用 auto / up / install / rebuild）"
        ;;
esac
