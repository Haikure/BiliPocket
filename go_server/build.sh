#!/bin/bash

set -euo pipefail

# 获取脚本所在目录并进入
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "编译主服务"
cd main
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o ../server && echo "success"

echo "编译短信服务"
cd ../sms
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o ../bili-sms && echo "success"
