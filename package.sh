#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

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

# 打包
(
    cd "$PACKAGE_STAGE"
    zip -r bili_plugin.zip bili_plugin
)
mv "$PACKAGE_STAGE/bili_plugin.zip" "$PROJECT_DIR/bili_plugin.zip"
echo '打包完成'
