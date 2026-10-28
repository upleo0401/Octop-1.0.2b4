#!/usr/bin/env bash
# =============================================================================
# 给正在运行的 octop 容器安装知识库向量运行时（fastembed）
#
# 不删数据、不重建 PostgreSQL、不换应用镜像。
# 「运行时组件未安装」= 容器里没有 Python 包 fastembed，模型权重可以已经在。
#
# 服务器（root）：
#   bash /home/ops/install-embedding-runtime.sh
# =============================================================================
set -euo pipefail

export PATH="/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

NAME="${OCTOP_CONTAINER:-octop}"
PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.cloud.tencent.com/pypi/simple}"
PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-mirrors.cloud.tencent.com}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"
command -v docker >/dev/null 2>&1 || die "找不到 docker（确认 PATH 含 /home/bin）"
docker inspect "$NAME" >/dev/null 2>&1 || die "容器 ${NAME} 不存在"

echo "=============================================="
echo "安装向量运行时到容器 ${NAME}"
echo "不删除 /home/octop-data/.octop ，不碰 octop-postgres"
echo "=============================================="

echo
echo "---- 安装前 ----"
docker exec "$NAME" python -c "import fastembed; print('fastembed', getattr(fastembed,'__version__','ok'))" \
    2>/dev/null && { echo "已安装，无需再装。刷新知识库设置页即可。"; exit 0; } || echo "fastembed: 未安装"

echo
echo "---- 安装 fastembed（腾讯云 PyPI）----"
docker exec \
    -e PIP_INDEX_URL="$PIP_INDEX_URL" \
    -e PIP_TRUSTED_HOST="$PIP_TRUSTED_HOST" \
    -e UV_INDEX_URL="$PIP_INDEX_URL" \
    -e UV_INSECURE_HOST="$PIP_TRUSTED_HOST" \
    "$NAME" \
    sh -c '
set -eu
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
    for c in /app/.venv/bin/python python3 python; do
        command -v "$c" >/dev/null 2>&1 && PY="$c" && break
        [ -x "$c" ] && PY="$c" && break
    done
fi
[ -n "$PY" ] || { echo "找不到 python"; exit 1; }
echo "python: $PY"
IDX="${PIP_INDEX_URL:-https://mirrors.cloud.tencent.com/pypi/simple}"
HOST="${PIP_TRUSTED_HOST:-mirrors.cloud.tencent.com}"
install_uv() {
    UV=""
    for c in uv /bin/uv /usr/local/bin/uv /app/.venv/bin/uv; do
        command -v "$c" >/dev/null 2>&1 && UV="$c" && break
        [ -x "$c" ] && UV="$c" && break
    done
    [ -n "$UV" ] || return 1
    echo "uv: $UV"
    "$UV" pip install --python "$PY" "fastembed>=0.4" "huggingface_hub>=0.20"
}
install_pip() {
    echo "pip: $PY -m pip"
    "$PY" -m pip install -i "$IDX" --trusted-host "$HOST" \
        "fastembed>=0.4" "huggingface_hub>=0.20"
}
install_uv || install_pip
'

echo
echo "---- 安装后校验 ----"
docker exec "$NAME" python -c "import fastembed, huggingface_hub; print('fastembed ok')" \
    || die "安装后仍无法 import fastembed"

echo
echo "---- 重启应用容器（保留原环境变量和挂载，含 PostgreSQL）----"
docker restart "$NAME"

health="000"
for i in $(seq 1 40); do
    health="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
        "http://127.0.0.1:${OCTOP_PORT:-8088}/api/health" 2>/dev/null || echo 000)"
    echo "  $(date +%T) health=${health}"
    if [ "$health" = "200" ]; then
        break
    fi
    sleep 3
done
[ "$health" = "200" ] || die "重启后未就绪 health=${health}。docker logs --tail 80 ${NAME}"

echo
echo "完成。刷新知识库设置，「运行时组件」应为已安装。不必重装客户端。"
echo "注意：下次 bash rebuild.sh 换新镜像后，若 Dockerfile 未带 --extra local-embedding，需要再跑本脚本。"
