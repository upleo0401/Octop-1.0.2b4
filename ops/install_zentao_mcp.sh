#!/usr/bin/env bash
# =============================================================================
# 在 Octop Docker 容器内安装禅道 MCP（stdio），文件落在数据卷，重建容器不丢。
#
# 宝塔/面板执行 bash 时经常吞掉命令行参数（$#=0），所以账号写在脚本开头。
# 改好下面三行后执行：  bash /home/ops/install_zentao_mcp.sh
# =============================================================================
ZENTAO_URL="http://192.168.3.112:18080/zentao"
ZENTAO_ACCOUNT="admin"
ZENTAO_PASSWORD="在这里填写禅道密码"

set -e

export PATH="/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

NAME="${OCTOP_CONTAINER:-octop}"
NODE_VER="${NODE_VER:-v20.18.3}"
NPM_REGISTRY="${NPM_REGISTRY:-https://mirrors.cloud.tencent.com/npm/}"
NODE_MIRROR="${NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
MCP_PKG="${MCP_PKG:-@wzdbsqb/mcp-zentao}"

PREFIX="/data/.octop/mcp"
NODE_DIR="${PREFIX}/node"
APP_DIR="${PREFIX}/zentao"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==== %s ====\n' "$*"; }

ZENTAO_URL="$(printf '%s' "$ZENTAO_URL" | tr -d '\r')"
ZENTAO_ACCOUNT="$(printf '%s' "$ZENTAO_ACCOUNT" | tr -d '\r')"
ZENTAO_PASSWORD="$(printf '%s' "$ZENTAO_PASSWORD" | tr -d '\r')"

if [ -z "$ZENTAO_URL" ] || [ -z "$ZENTAO_ACCOUNT" ] || [ -z "$ZENTAO_PASSWORD" ] \
    || [ "$ZENTAO_PASSWORD" = "在这里填写禅道密码" ]; then
    die "请用 vi 打开本脚本，改文件开头的 ZENTAO_PASSWORD，保存后再执行 bash /home/ops/install_zentao_mcp.sh（不要加参数）"
fi
command -v docker >/dev/null 2>&1 || die "找不到 docker，先 export PATH=/home/bin:\$PATH"
docker info >/dev/null 2>&1 || die "dockerd 未运行，先 bash /home/octop.sh"
docker ps --format '{{.Names}}' | grep -qx "$NAME" || die "容器 ${NAME} 未在运行"

log "在容器 ${NAME} 内安装 Node ${NODE_VER} 和 ${MCP_PKG}"
INNER=/tmp/octop-zentao-inner.sh
cat > "$INNER" <<'INSIDE'
#!/bin/bash
set -eu
mkdir -p "$NODE_DIR" "$APP_DIR"
if [ ! -x "$NODE_DIR/bin/node" ]; then
    tgz="/tmp/node-${NODE_VER}-linux-x64.tar.gz"
    curl -fL --retry 3 -o "$tgz" \
        "${NODE_MIRROR}/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.gz"
    tar -xzf "$tgz" -C /tmp
    rm -rf "$NODE_DIR"
    mv /tmp/node-${NODE_VER}-linux-x64 "$NODE_DIR"
    rm -f "$tgz"
fi
export PATH="$NODE_DIR/bin:$PATH"
"$NODE_DIR/bin/node" -v
cd "$APP_DIR"
rm -rf "$APP_DIR/node_modules" "$APP_DIR/package-lock.json"
printf '%s\n' '{"name":"octop-zentao-mcp","private":true}' > "$APP_DIR/package.json"
if ! "$NODE_DIR/bin/npm" install "$MCP_PKG" --registry "$NPM_REGISTRY"; then
    echo "腾讯云 npm 失败，改走 npmjs.org"
    "$NODE_DIR/bin/npm" install "$MCP_PKG" --registry https://registry.npmjs.org/
fi
pkg="$APP_DIR/node_modules/@wzdbsqb/mcp-zentao"
[ -d "$pkg" ] || pkg="$APP_DIR/node_modules/${MCP_PKG}"
[ -d "$pkg" ] || { echo "安装后目录不存在:"; ls -la "$APP_DIR" "$APP_DIR/node_modules" 2>/dev/null || true; exit 1; }
entry=""
for f in "$pkg/dist/index.js" "$pkg/build/index.js" "$pkg/index.js" "$pkg/src/index.js"; do
    if [ -f "$f" ]; then entry="$f"; break; fi
done
if [ -z "$entry" ]; then
    echo "包内文件:"; find "$pkg" -maxdepth 3 -type f | head -40
    exit 1
fi
printf '%s\n' '#!/bin/bash' \
    "export PATH=\"${NODE_DIR}/bin:\$PATH\"" \
    "cd \"${APP_DIR}\"" \
    "exec \"${NODE_DIR}/bin/node\" \"${entry}\" \"\$@\"" \
    > "$APP_DIR/run.sh"
chmod +x "$APP_DIR/run.sh"
echo "入口: $entry"
INSIDE
docker cp "$INNER" "${NAME}:/tmp/octop-zentao-inner.sh"
docker exec \
    -e NODE_VER="$NODE_VER" -e NODE_MIRROR="$NODE_MIRROR" \
    -e NPM_REGISTRY="$NPM_REGISTRY" -e MCP_PKG="$MCP_PKG" \
    -e PREFIX="$PREFIX" -e NODE_DIR="$NODE_DIR" -e APP_DIR="$APP_DIR" \
    "$NAME" bash /tmp/octop-zentao-inner.sh

HOST_APP="${OCTOP_DATA_DIR:-/home/octop-data/.octop}/mcp/zentao"
mkdir -p "$HOST_APP"
cat > "$HOST_APP/octop-connector.json" <<EOF
{
  "zentao": {
    "transport": "stdio",
    "enabled": true,
    "display_name": "禅道",
    "command": "${APP_DIR}/run.sh",
    "env": {
      "ZENTAO_URL": "${ZENTAO_URL}",
      "ZENTAO_BASE_URL": "${ZENTAO_URL}",
      "ZENTAO_BASEURL": "${ZENTAO_URL}",
      "ZENTAO_ACCOUNT": "${ZENTAO_ACCOUNT}",
      "ZENTAO_USERNAME": "${ZENTAO_ACCOUNT}",
      "ZENTAO_PASSWORD": "${ZENTAO_PASSWORD}",
      "ZENTAO_API_VERSION": "v1"
    }
  }
}
EOF
rm -f "$INNER"

echo
echo "=============================================="
echo "禅道 MCP 已装到容器 ${APP_DIR}（数据卷持久化）"
echo
echo "接下来在 Octop 网页："
echo "  连接器 → 自定义 MCP → 添加 Stdio"
echo "  名称: zentao"
echo "  命令: ${APP_DIR}/run.sh"
echo "  环境变量:"
echo "    ZENTAO_URL=${ZENTAO_URL}"
echo "    ZENTAO_USERNAME=${ZENTAO_ACCOUNT}"
echo "    ZENTAO_PASSWORD=******"
echo "    ZENTAO_ACCOUNT=${ZENTAO_ACCOUNT}"
echo "保存后，到专家/智能体里打开该连接器。"
echo "配置副本: docker exec ${NAME} cat /data/.octop/mcp/zentao/octop-connector.json"
echo "=============================================="
