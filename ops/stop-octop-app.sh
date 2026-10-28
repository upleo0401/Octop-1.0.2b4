#!/usr/bin/env bash
# =============================================================================
# 停止 Linux 上的 Octop HTTP 应用（方案 A：只留公司 PostgreSQL）。
#
# 会停：systemd 单元 octop.service、名为 octop 的应用容器。
# 不会停：octop-postgres / PostgreSQL。
#
# 服务器（root）：
#   bash /home/ops/stop-octop-app.sh
#   bash /home/ops/stop-octop-app.sh --disable   # 同时关掉开机自启与容器自动重启
# =============================================================================
set -euo pipefail

export PATH="/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OCTOP_NAME="${OCTOP_CONTAINER:-octop}"
PG_NAME="${OCTOP_PG_CONTAINER:-octop-postgres}"
DISABLE=0
[ "${1:-}" = "--disable" ] && DISABLE=1

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==== %s ====\n' "$*"; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"

is_postgres_name() {
    case "$1" in
        *postgres*|*pgvector*|"$PG_NAME") return 0 ;;
        *) return 1 ;;
    esac
}

stop_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl list-unit-files octop.service >/dev/null 2>&1 \
        || systemctl status octop.service >/dev/null 2>&1; then
        log "停止 systemd octop.service"
        systemctl stop octop.service || true
        if [ "$DISABLE" = 1 ]; then
            systemctl disable octop.service || true
            echo "已 disable octop.service"
        fi
    else
        echo "未安装 systemd 单元 octop.service，跳过"
    fi
}

stop_docker_app() {
    command -v docker >/dev/null 2>&1 || {
        echo "找不到 docker，跳过容器"
        return 0
    }
    docker info >/dev/null 2>&1 || {
        echo "dockerd 未运行，跳过容器"
        return 0
    }

    names="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
    [ -n "$names" ] || {
        echo "没有 Docker 容器"
        return 0
    }

    log "停止 Octop 应用容器（保留 ${PG_NAME}）"
    stopped=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        is_postgres_name "$name" && continue
        case "$name" in
            "$OCTOP_NAME"|octop|octop-app|octop-server|octop-web)
                ;;
            octop-*)
                ;;
            *)
                continue
                ;;
        esac
        echo "停止容器 $name"
        if [ "$DISABLE" = 1 ]; then
            docker update --restart=no "$name" >/dev/null 2>&1 || true
        fi
        docker stop "$name" >/dev/null
        stopped=1
    done <<EOF
$names
EOF
    [ "$stopped" = 1 ] || echo "没有正在跑的 Octop 应用容器"
}

stop_systemd
stop_docker_app

log "检查"
if command -v docker >/dev/null 2>&1 && docker inspect "$PG_NAME" >/dev/null 2>&1; then
    if docker inspect -f '{{.State.Running}}' "$PG_NAME" 2>/dev/null | grep -qx true; then
        echo "PostgreSQL 容器 ${PG_NAME}：仍在运行（预期）"
    else
        echo "警告：PostgreSQL 容器 ${PG_NAME} 未在运行。需要时：docker start ${PG_NAME}"
    fi
fi

if command -v ss >/dev/null 2>&1; then
    if ss -lnt '( sport = :8088 )' 2>/dev/null | grep -q 8088; then
        echo "警告：8088 仍在监听。用 ss -lntp | grep 8088 查进程后手动停。"
    else
        echo "8088：未监听"
    fi
fi

echo
echo "=============================================="
echo "Octop 应用已停止。公司 PostgreSQL 保持不动。"
echo "Windows 客户端继续连库即可，不必再连这台机的 8088。"
if [ "$DISABLE" = 1 ]; then
    echo "已禁止 systemd 开机自启，应用容器 restart 策略改为 no。"
else
    echo "若开机或 compose 会再拉起应用：bash $0 --disable"
fi
echo "=============================================="
