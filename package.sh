#!/bin/bash

set -euo pipefail

pwd=$(pwd)
echo '当前目录：'
echo $pwd

echo '编译插件'
xmake

echo '编译Go服务器'
cd $pwd/go_server
./build.sh
cd $pwd
echo '----------------'

# 临时文件
mkdir bili_plugin
cp go_server/server ./bili_plugin
cp go_server/bili-sms ./bili_plugin
cp build/linux/arm64-v8a/release/libbili_plugin.so ./bili_plugin
cp -r ./qml ./bili_plugin
cp metadata.json ./bili_plugin
cp icon.png ./bili_plugin

# 打包
zip -r bili_plugin.zip bili_plugin/*

# 清除

rm -r ./bili_plugin

echo '----------------'
echo '打包完成'
