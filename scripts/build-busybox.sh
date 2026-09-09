#!/usr/bin/env bash
# 交叉编译静态 busybox, 产物: out/busybox/busybox (armhf 静态)
set -euo pipefail
. "$(dirname "$0")/env.sh"

[ -f "${BUSYBOX_SRC}/Makefile" ] || die "busybox 源码不存在, 先运行 make fetch"

BOUT="${OUT_DIR}/busybox"
mkdir -p "${BOUT}"

if [ ! -f "${BOUT}/.config" ]; then
  make -C "${BUSYBOX_SRC}" O="${BOUT}" defconfig
  # 静态链接: 根文件系统无需部署 glibc
  sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "${BOUT}/.config"
  make -C "${BUSYBOX_SRC}" O="${BOUT}" oldconfig
fi

make -C "${BUSYBOX_SRC}" O="${BOUT}" CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}"

file "${BOUT}/busybox" | grep -q 'ARM' || die "busybox 交叉编译结果异常"
log "busybox 编译完成: $(ls -lh "${BOUT}/busybox" | awk '{print $5, $9}')"
