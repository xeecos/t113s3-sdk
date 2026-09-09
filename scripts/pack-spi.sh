#!/usr/bin/env bash
# 打包 SPI NOR flash 镜像: out/images/t113-spi.img
#
# 布局 (SPI_FLASH_SIZE_MB, 默认 16M):
#   0x000000  U-Boot (SPL+U-Boot, <=512K)
#   0x080000  dtb (64K)   <- ${BOARD_DTS_NAME}.dtb
#   0x100000  zImage (12M)   <- 内核 6.6 zImage 约 10.5M, 10M 分区放不下
#   0xD00000  rootfs.squashfs (可选, SPI_ROOTFS=1, 只读根文件系统)
#
# U-Boot 默认启动流程: SPI flash 全 NOR 系统优先, 失败后 SD 卡 distro 启动
# (bootcmd 与 mtdparts 见 configs/uboot/t113_s3.config)
set -euo pipefail
. "$(dirname "$0")/env.sh"

UBOOT_BIN="${OUT_DIR}/uboot/u-boot-sunxi-with-spl.bin"
DTB_FILE="${IMG_DIR}/${BOARD_DTS_NAME}.dtb"
require_file "${UBOOT_BIN}"
require_file "${IMG_DIR}/zImage"
require_file "${DTB_FILE}"

# ---- 布局常量 (字节) ----
OFF_UBOOT=0
SZ_UBOOT=$(( 512 * 1024 ))
OFF_DTB=$(( 0x80000 ))
SZ_DTB=$(( 64 * 1024 ))
OFF_KERN=$(( 0x100000 ))
SZ_KERN=$(( 0xD00000 - 0x100000 ))        # 12M
OFF_ROOTFS=$(( 0xD00000 ))
FLASH_SIZE=$(( SPI_FLASH_SIZE_MB * 1024 * 1024 ))
SZ_ROOTFS=$(( FLASH_SIZE - OFF_ROOTFS ))

IMG="${IMG_DIR}/t113-spi.img"

check_fit() { # $1=文件 $2=分区大小 $3=名称
  local size
  size=$(stat -c%s "$1")
  [ "${size}" -le "$2" ] || die "$3 (${size}B) 超过分区上限 ($2B)"
}

check_fit "${UBOOT_BIN}" "${SZ_UBOOT}" "u-boot-sunxi-with-spl.bin"
check_fit "${DTB_FILE}" "${SZ_DTB}" "dtb"
check_fit "${IMG_DIR}/zImage" "${SZ_KERN}" "zImage"

# ---- 可选: squashfs 只读 rootfs (从 out/rootfs.ext4 抽取后压缩) ----
ROOTFS_SQFS="/tmp/rootfs.squashfs"
if [ "${SPI_ROOTFS}" = "1" ]; then
  require_file "${OUT_DIR}/rootfs.ext4"
  log "生成 squashfs rootfs (zstd, 只读)"
  rm -rf /tmp/sqfs-root "${ROOTFS_SQFS}"
  mkdir -p /tmp/sqfs-root
  debugfs -R "rdump / /tmp/sqfs-root" "${OUT_DIR}/rootfs.ext4" >/dev/null 2>&1
  mksquashfs /tmp/sqfs-root "${ROOTFS_SQFS}" -comp zstd -b 256K -all-root -no-xattrs -no-progress
  check_fit "${ROOTFS_SQFS}" "${SZ_ROOTFS}" "rootfs.squashfs"
fi

# ---- 拼接 flash 镜像 ----
log "拼接 ${IMG} (${SPI_FLASH_SIZE_MB}M)"
rm -f "${IMG}"
truncate -s "${FLASH_SIZE}" "${IMG}"

dd if="${UBOOT_BIN}" of="${IMG}" bs=1k seek=$(( OFF_UBOOT / 1024 )) conv=notrunc status=none
dd if="${DTB_FILE}" of="${IMG}" bs=1k seek=$(( OFF_DTB / 1024 )) conv=notrunc status=none
dd if="${IMG_DIR}/zImage" of="${IMG}" bs=1k seek=$(( OFF_KERN / 1024 )) conv=notrunc status=none
if [ "${SPI_ROOTFS}" = "1" ]; then
  dd if="${ROOTFS_SQFS}" of="${IMG}" bs=1k seek=$(( OFF_ROOTFS / 1024 )) conv=notrunc status=none
  cp "${ROOTFS_SQFS}" "${IMG_DIR}/rootfs.squashfs"
fi

# ---- SPI 更新脚本 (放到 SD 卡 boot 分区, U-Boot 下刷新 SPI 用) ----
log "生成 spi-update.scr"
mkimage -T script -C none -n "spi update" -d "${ROOT_DIR}/board/spi-update.cmd" "${IMG_DIR}/spi-update.scr"

log "SPI flash 镜像打包完成: ${IMG}"
if [ "${SPI_ROOTFS}" = "1" ]; then
  log "全 NOR 启动: U-Boot 已内置 bootargs (含 mtdparts=spi0.0:512k(uboot)ro,64k(dtb),12m(kernel),-(rootfs) root=/dev/mtdblock3 rootfstype=squashfs)"
fi
log "烧写方式:"
log "  1) U-Boot 命令行: 插 SD 卡 -> fatload mmc 0:1 \${scriptaddr} spi-update.scr; source \${scriptaddr}"
log "  2) Linux 运行中 : flashcp t113-spi.img /dev/mtd0  (或分分区 mtd write)"
log "  3) FEL (USB)    : sunxi-fel spiflash-write 0 t113-spi.img"
ls -lh "${IMG_DIR}"
