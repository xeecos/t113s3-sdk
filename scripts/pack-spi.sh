#!/usr/bin/env bash
# 打包 SPI flash 镜像: out/images/t113-spi.img
#
# 布局由 config/board.env 的 SPI_FLASH_TYPE 决定 (见 scripts/env.sh 的 spi_layout):
#   nor : 0x000000 uboot(512K) | 0x080000 dtb(64K)  | 0x100000 kernel(12M) | 0xD00000 rootfs.squashfs
#   nand: 0x000000 uboot(1M)   | 0x100000 dtb(256K) | 0x140000 kernel(16M) | 0x1140000 rootfs.squashfs
# 同一份分区表也写在 board/dts 与 board/uboot-dts 的 partitions 节点里 (内核/U-Boot 共用),
# 本脚本打包前会校验两者一致, 不一致直接报错。
#
# SPI NAND (Winbond W25N02KVZEIR): 2048B 页 + 128B OOB, 128KB 擦除块。
#   镜像本体是不含 OOB 的"线性"内容, 不能直接 dd 进 flash —— 必须经 MTD 层写入
#   (U-Boot 里 mtd write / Linux 里 flashcp / FEL 下 xfel spi_nand write),
#   否则 OOB 与 ECC 不会正确生成。
#
# U-Boot 默认启动流程: SPI flash 系统优先, 失败后 SD 卡 distro 启动
# (bootcmd 见 configs/uboot/t113_s3.config)
set -euo pipefail
. "$(dirname "$0")/env.sh"

spi_layout
check_dts_partitions "${ROOT_DIR}/board/dts/${BOARD_DTS_NAME}.dts"

UBOOT_BIN="${OUT_DIR}/uboot/u-boot-sunxi-with-spl.bin"
DTB_FILE="${IMG_DIR}/${BOARD_DTS_NAME}.dtb"
require_file "${UBOOT_BIN}"
require_file "${IMG_DIR}/zImage"
require_file "${DTB_FILE}"

IMG="${IMG_DIR}/t113-spi.img"
FLASH_SIZE=$(( SPI_FLASH_SIZE_MB * 1024 * 1024 ))
[ "${SPI_ROOTFS_SIZE}" -gt 0 ] \
  || die "SPI_FLASH_SIZE_MB=${SPI_FLASH_SIZE_MB} 太小, 放不下 kernel 分区 (到 0x$(printf %x "${SPI_OFF_ROOTFS}"))"

# dtb 里必须真的有 flash 节点, 否则内核不会创建 /dev/mtd*, 启动时找不到
# root=/dev/mtdblock3。上游参考板 DTS 没有 spi0/flash 节点, 用 KERNEL_DTS=auto
# 编出来的 dtb 就会踩这个坑, 所以在打包这一步直接拦住。
if command -v dtc >/dev/null 2>&1; then
  want_compat="compatible = \"spi-nand\""
  [ "${SPI_FLASH_TYPE}" = "nand" ] || want_compat="compatible = \"jedec,spi-nor\""
  # 注意: 这里不能用 "dtc ... | grep -q" —— grep -q 命中后立刻退出会让 dtc 收到
  # SIGPIPE, 在 set -o pipefail 下整条管道就算失败。所以先取文本再匹配。
  dts_txt="$(dtc -I dtb -O dts "${DTB_FILE}" 2>/dev/null || true)"
  if ! grep -qF "${want_compat}" <<<"${dts_txt}"; then
    die "${DTB_FILE} 里没有 ${want_compat} 节点 — 多半是 KERNEL_DTS=auto 编的 (上游参考板 DTS 不含 spi0/flash)。请用 KERNEL_DTS=board make kernel 重新生成后再打包"
  fi
fi

# SPI NAND 的分区必须落在擦除块边界上 (W25N02KV: 128KB), 否则内核/U-Boot 都不认该分区
if [ "${SPI_FLASH_TYPE}" = "nand" ]; then
  for v in SPI_UBOOT_SIZE SPI_DTB_SIZE SPI_KERNEL_SIZE SPI_ROOTFS_SIZE; do
    [ "$(( ${!v} % 131072 ))" -eq 0 ] \
      || die "SPI NAND 分区必须按 128KB 擦除块对齐: ${v}=${!v} (改 config/board.env)"
  done
fi

hex() { printf '0x%x' "$1"; }
log "SPI flash: ${SPI_FLASH_TYPE}, ${SPI_FLASH_SIZE_MB}M$([ "${SPI_FLASH_TYPE}" = nand ] && echo " (Winbond W25N02KVZEIR SPI NAND)")"
printf '  %-8s %-10s %-12s %s\n' 分区 起始 大小 内容
printf '  %-8s %-10s %-12s %s\n' uboot  "$(hex "${SPI_OFF_UBOOT}")"  "$(hex "${SPI_UBOOT_SIZE}")"  "u-boot-sunxi-with-spl.bin"
printf '  %-8s %-10s %-12s %s\n' dtb    "$(hex "${SPI_OFF_DTB}")"    "$(hex "${SPI_DTB_SIZE}")"    "${BOARD_DTS_NAME}.dtb"
printf '  %-8s %-10s %-12s %s\n' kernel "$(hex "${SPI_OFF_KERNEL}")" "$(hex "${SPI_KERNEL_SIZE}")" "zImage"
printf '  %-8s %-10s %-12s %s\n' rootfs "$(hex "${SPI_OFF_ROOTFS}")" "$(hex "${SPI_ROOTFS_SIZE}")" "rootfs.squashfs"

check_fit() { # $1=文件 $2=分区大小 $3=名称
  local size
  size=$(stat -c%s "$1")
  [ "${size}" -le "$2" ] || die "$3 (${size}B) 超过分区上限 ($2B)"
}

check_fit "${UBOOT_BIN}" "${SPI_UBOOT_SIZE}" "u-boot-sunxi-with-spl.bin"
check_fit "${DTB_FILE}" "${SPI_DTB_SIZE}" "dtb"
check_fit "${IMG_DIR}/zImage" "${SPI_KERNEL_SIZE}" "zImage"

# ---- 可选: squashfs 只读 rootfs (从 out/rootfs.ext4 抽取后压缩) ----
ROOTFS_SQFS="/tmp/rootfs.squashfs"
if [ "${SPI_ROOTFS}" = "1" ]; then
  require_file "${OUT_DIR}/rootfs.ext4"
  log "生成 squashfs rootfs (zstd, 只读)"
  rm -rf /tmp/sqfs-root "${ROOTFS_SQFS}"
  mkdir -p /tmp/sqfs-root
  debugfs -R "rdump / /tmp/sqfs-root" "${OUT_DIR}/rootfs.ext4" >/dev/null 2>&1
  mksquashfs /tmp/sqfs-root "${ROOTFS_SQFS}" -comp zstd -b 256K -all-root -no-xattrs -no-progress
  check_fit "${ROOTFS_SQFS}" "${SPI_ROOTFS_SIZE}" "rootfs.squashfs"
fi

# ---- 拼接 flash 镜像 ----
log "拼接 ${IMG} (${SPI_FLASH_SIZE_MB}M)"
rm -f "${IMG}"
truncate -s "${FLASH_SIZE}" "${IMG}"

dd if="${UBOOT_BIN}" of="${IMG}" bs=1k seek=$(( SPI_OFF_UBOOT / 1024 )) conv=notrunc status=none
dd if="${DTB_FILE}" of="${IMG}" bs=1k seek=$(( SPI_OFF_DTB / 1024 )) conv=notrunc status=none
dd if="${IMG_DIR}/zImage" of="${IMG}" bs=1k seek=$(( SPI_OFF_KERNEL / 1024 )) conv=notrunc status=none
if [ "${SPI_ROOTFS}" = "1" ]; then
  dd if="${ROOTFS_SQFS}" of="${IMG}" bs=1k seek=$(( SPI_OFF_ROOTFS / 1024 )) conv=notrunc status=none
  cp "${ROOTFS_SQFS}" "${IMG_DIR}/rootfs.squashfs"
fi

# ---- 更新脚本 (拷到 SD 卡 boot 分区, U-Boot 下 source 它刷新 SPI flash) ----
if [ "${SPI_FLASH_TYPE}" = "nand" ]; then
  log "生成 spi-nand-update.scr"
  mkimage -T script -C none -n "spi nand update" \
    -d "${ROOT_DIR}/board/spi-nand-update.cmd" "${IMG_DIR}/spi-nand-update.scr"
else
  log "生成 spi-update.scr"
  mkimage -T script -C none -n "spi update" \
    -d "${ROOT_DIR}/board/spi-update.cmd" "${IMG_DIR}/spi-update.scr"
fi

log "SPI flash 镜像打包完成: ${IMG}"
log "启动: 分区表来自板级 DT, rootfs 是第 4 个分区 -> root=/dev/mtdblock3 (squashfs)"

if [ "${SPI_FLASH_TYPE}" = "nand" ]; then
  log "SPI NAND 不能用 dd/flashcp 写整片镜像, 必须经 MTD 层写 (OOB/ECC 由驱动生成):"
  log "  1) U-Boot 命令行: 插 SD 卡 -> fatload mmc 0:1 \${scriptaddr} spi-nand-update.scr; source \${scriptaddr}"
  log "  2) Linux 运行中 : 按分区写单个文件, 例: flashcp zImage /dev/mtd2"
  log "  3) FEL (USB)    : xfel spi_nand write 0 t113-spi.img  (整片, 256M 较慢)"
else
  log "烧写方式:"
  log "  1) U-Boot 命令行: 插 SD 卡 -> fatload mmc 0:1 \${scriptaddr} spi-update.scr; source \${scriptaddr}"
  log "  2) Linux 运行中 : 按分区写, 例: flashcp zImage /dev/mtd2"
  log "  3) FEL (USB)    : sunxi-fel spiflash-write 0 t113-spi.img"
fi
ls -lh "${IMG_DIR}"
