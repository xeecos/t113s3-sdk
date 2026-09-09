#!/usr/bin/env bash
# 打包可启动 SD 卡镜像: out/images/t113-sdcard.img
#
# 布局:
#   [0 .. 8KiB)          保留 (分区表)
#   [8KiB)               U-Boot SPL+U-Boot (u-boot-sunxi-with-spl.bin)
#   [8MiB .. 136MiB)     p1 FAT32  boot: boot.scr / zImage / dtb
#   [136MiB .. 结束)     p2 ext4   rootfs
set -euo pipefail
. "$(dirname "$0")/env.sh"

UBOOT_BIN="${OUT_DIR}/uboot/u-boot-sunxi-with-spl.bin"
ROOTFS_IMG="${OUT_DIR}/rootfs.ext4"
DTB_FILE="${IMG_DIR}/${BOARD_DTS_NAME}.dtb"
require_file "${UBOOT_BIN}"
require_file "${ROOTFS_IMG}"
require_file "${IMG_DIR}/zImage"
require_file "${DTB_FILE}"

IMG="${IMG_DIR}/t113-sdcard.img"
BOOT_IMG="${OUT_DIR}/boot.img"

OFF_BOOT_MB="${SD_BOOT_OFFSET_MB}"
SZ_BOOT_MB="${SD_BOOT_SIZE_MB}"
OFF_ROOT_MB=$(( OFF_BOOT_MB + SZ_BOOT_MB ))
# 扇区数 (512B)
SEC_BOOT=$(( OFF_BOOT_MB * 2048 ))
SEC_ROOT=$(( OFF_ROOT_MB * 2048 ))
SEC_BOOT_END=$(( SZ_BOOT_MB * 2048 ))
ROOT_MB=$(du -m "${ROOTFS_IMG}" | cut -f1)
IMG_MB=$(( OFF_ROOT_MB + ROOT_MB + 4 ))

# ---- 1. boot.scr ----
log "生成 boot.scr"
mkimage -T script -C none -n "t113-s3 boot" -d "${BOOT_CMD}" "${IMG_DIR}/boot.scr"

# ---- 2. boot 分区镜像 (FAT32, mtools 免挂载填充) ----
log "制作 boot 分区 (${SZ_BOOT_MB}M FAT32)"
rm -f "${BOOT_IMG}"
truncate -s "${SZ_BOOT_MB}M" "${BOOT_IMG}"
mkfs.vfat -F 32 -n BOOT "${BOOT_IMG}" >/dev/null
mcopy -i "${BOOT_IMG}" "${IMG_DIR}/boot.scr"   ::boot.scr
mcopy -i "${BOOT_IMG}" "${IMG_DIR}/zImage"     ::zImage
mcopy -i "${BOOT_IMG}" "${IMG_DIR}/${BOARD_DTS_NAME}.dtb" ::"${BOARD_DTS_NAME}.dtb"
# SPI flash 更新脚本 (U-Boot 下 source 它即可把 zImage/dtb 刷入 SPI)
if [ -f "${IMG_DIR}/spi-update.scr" ]; then
  mcopy -i "${BOOT_IMG}" "${IMG_DIR}/spi-update.scr" ::spi-update.scr
fi

# ---- 3. 拼接整卡镜像 ----
log "拼接 ${IMG} (${IMG_MB}M)"
rm -f "${IMG}"
truncate -s "${IMG_MB}M" "${IMG}"

dd if="${UBOOT_BIN}" of="${IMG}" bs=1k seek=8 conv=notrunc status=none

sfdisk "${IMG}" <<EOF >/dev/null
label: dos
start=${SEC_BOOT}, size=${SEC_BOOT_END}, type=0c, bootable
start=${SEC_ROOT}, type=83
EOF

dd if="${BOOT_IMG}"  of="${IMG}" bs=512 seek="${SEC_BOOT}" conv=notrunc status=none
dd if="${ROOTFS_IMG}" of="${IMG}" bs=512 seek="${SEC_ROOT}" conv=notrunc status=none
rm -f "${BOOT_IMG}"

log "SD 卡镜像打包完成: ${IMG}"
fdisk -l "${IMG}" | tail -4
ls -lh "${IMG_DIR}"
log "部署: make flash DEV=/dev/diskN (macOS) 或 DEV=/dev/sdX (Linux/WSL2), 详见 README"
