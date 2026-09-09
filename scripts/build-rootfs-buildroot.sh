#!/usr/bin/env bash
# 用 Buildroot 构建完整根文件系统 (glibc + busybox + 可扩展软件包)
# 产物: out/buildroot/images/rootfs.ext4, 同时复制到 out/rootfs.ext4 供 make pack 使用
# 板级软件包在 configs/buildroot/${CONFIG_STEM}_defconfig 里增删
set -euo pipefail
. "$(dirname "$0")/env.sh"

BUILDROOT_REF="2024.02.6"   # 2024.02 LTS

if [ ! -f "${BUILDROOT_SRC}/Makefile" ]; then
  log "克隆 buildroot ${BUILDROOT_REF}"
  ok=0
  for url in "${BUILDROOT_GIT_LIST[@]}"; do
    if git clone --depth 1 --branch "${BUILDROOT_REF}" "${url}" "${BUILDROOT_SRC}"; then ok=1; break; fi
    warn "克隆失败, 换下一个镜像..."; rm -rf "${BUILDROOT_SRC}"
  done
  [ "${ok}" = 1 ] || die "buildroot 克隆失败"
fi

mkdir -p "${OUT_DIR}/buildroot"
cp "${ROOT_DIR}/configs/buildroot/${CONFIG_STEM}_defconfig" "${BUILDROOT_SRC}/configs/"

make -C "${BUILDROOT_SRC}" O="${OUT_DIR}/buildroot" BR2_JLEVEL="${JOBS}" "${CONFIG_STEM}_defconfig"
make -C "${BUILDROOT_SRC}" O="${OUT_DIR}/buildroot" BR2_JLEVEL="${JOBS}"

require_file "${OUT_DIR}/buildroot/images/rootfs.ext4"
cp "${OUT_DIR}/buildroot/images/rootfs.ext4" "${OUT_DIR}/rootfs.ext4"
log "buildroot 根文件系统完成: out/rootfs.ext4"
