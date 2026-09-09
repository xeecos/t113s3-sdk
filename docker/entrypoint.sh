#!/usr/bin/env bash
# 容器入口: 打印环境摘要后执行传入的命令
set -euo pipefail

echo "======== T113-S3 编译容器 ========"
echo "主机架构 : $(uname -m)"
echo "host gcc : $(gcc --version | head -1 | awk '{print $3}')"
echo "armhf gcc: $(arm-linux-gnueabihf-gcc --version | head -1 | awk '{print $4}')"
echo "dtc      : $(dtc --version | awk '{print $2}')"
echo "ccache   : $(ccache --version | head -1 | awk '{print $3}')"
echo "================================="
echo

exec "$@"
