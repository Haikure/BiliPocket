#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# 默认使用项目内附带的 ARM64 QML 模块
PLAYER_MODULE_DIR="${FFMPEGPLAYER_QML_DIR:-$PROJECT_DIR/qml/FFmpegPlayer}"
PLAYER_LIBRARY="$PLAYER_MODULE_DIR/libffmpegplayerplugin.so"
if [[ ! -f "$PLAYER_MODULE_DIR/qmldir" || ! -f "$PLAYER_LIBRARY" ]]; then
    echo "缺少 FFmpegPlayer 模块：$PLAYER_MODULE_DIR" >&2
    echo '请恢复 qml/FFmpegPlayer 中的播放器文件，或设置 FFMPEGPLAYER_QML_DIR 指向含 qmldir 与 libffmpegplayerplugin.so 的目录。' >&2
    exit 1
fi
if ! command -v readelf >/dev/null 2>&1; then
    echo '缺少 readelf（binutils），无法检查播放器架构。' >&2
    exit 1
fi
if ! LC_ALL=C readelf -h "$PLAYER_LIBRARY" | grep -Eq 'Machine:[[:space:]]+AArch64'; then
    echo "播放器必须是 ARM64 / AArch64 设备版本：$PLAYER_LIBRARY" >&2
    exit 1
fi
if ! grep -Eq '^module[[:space:]]+FFmpegPlayer[[:space:]]*$' "$PLAYER_MODULE_DIR/qmldir" ||
   ! grep -Eq '^plugin[[:space:]]+ffmpegplayerplugin[[:space:]]*$' "$PLAYER_MODULE_DIR/qmldir"; then
    echo "FFmpegPlayer 模块清单不匹配：$PLAYER_MODULE_DIR/qmldir" >&2
    exit 1
fi
echo "播放器模块：$PLAYER_MODULE_DIR"

echo '编译插件'
xmake

echo '编译Go服务器'
./go_server/build.sh

# 临时文件
PACKAGE_STAGE="$(mktemp -d "$PROJECT_DIR/.bili-package.XXXXXX")"
trap 'rm -rf -- "$PACKAGE_STAGE"' EXIT
mkdir "$PACKAGE_STAGE/bili_plugin"
cp go_server/server go_server/bili-sms build/linux/arm64-v8a/release/libbili_plugin.so \
    metadata.json icon.png "$PACKAGE_STAGE/bili_plugin/"
cp -R qml "$PACKAGE_STAGE/bili_plugin/"
# 默认播放器已随 qml 目录复制；显式指定其他版本时替换暂存模块。
if [[ -n "${FFMPEGPLAYER_QML_DIR:-}" ]]; then
    rm -rf -- "$PACKAGE_STAGE/bili_plugin/qml/FFmpegPlayer"
    mkdir -p "$PACKAGE_STAGE/bili_plugin/qml/FFmpegPlayer"
    cp -R "$PLAYER_MODULE_DIR/." "$PACKAGE_STAGE/bili_plugin/qml/FFmpegPlayer/"
fi

# 打包
(
    cd "$PACKAGE_STAGE"
    zip -r bili_plugin.zip bili_plugin
)
mv "$PACKAGE_STAGE/bili_plugin.zip" "$PROJECT_DIR/bili_plugin.zip"
echo '打包完成'
