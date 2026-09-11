#!/usr/bin/env bash
# ============================================================
# 通用环境: 所有容器内编译脚本 source 本文件
# ============================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/board.env
source "${ROOT_DIR}/config/board.env"

SRC_DIR="${ROOT_DIR}/sources"
OUT_DIR="${ROOT_DIR}/out"
IMG_DIR="${OUT_DIR}/images"
DL_DIR="${ROOT_DIR}/downloads"
mkdir -p "${SRC_DIR}" "${OUT_DIR}" "${IMG_DIR}" "${DL_DIR}"

KERNEL_SRC="${SRC_DIR}/linux"
UBOOT_SRC="${SRC_DIR}/uboot"
BUSYBOX_SRC="${SRC_DIR}/busybox"
BUILDROOT_SRC="${SRC_DIR}/buildroot"
ROOTFS_DIR="${OUT_DIR}/rootfs"
BOOT_CMD="${ROOT_DIR}/board/boot.cmd"

# ---------- 输出辅助 ----------
log()  { echo -e "\033[32m[build]\033[0m $*"; }
warn() { echo -e "\033[33m[warn ]\033[0m $*"; }
die()  { echo -e "\033[31m[error]\033[0m $*" >&2; exit 1; }
require_file() { [ -f "$1" ] || die "缺少产物 $1, 请先运行对应的 make 目标"; }

JOBS="$(nproc)"

# ---------- 源码仓库 (按 MIRROR 选择) ----------
case "${MIRROR}" in
  cn)
    UBOOT_GIT_LIST=(
      "https://mirrors.tuna.tsinghua.edu.cn/git/u-boot.git"
      "https://gitee.com/mirrors/u-boot.git"
      "https://source.denx.de/u-boot/u-boot.git"
    )
    BUILDROOT_GIT_LIST=(
      "https://mirrors.tuna.tsinghua.edu.cn/git/buildroot.git"
      "https://gitee.com/mirrors/buildroot.git"
      "https://gitlab.com/buildroot.org/buildroot.git"
    )
    KERNEL_TARBALL_LIST=(
      "https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x"
      "https://cdn.kernel.org/pub/linux/kernel/v6.x"
    )
    ;;
  *)
    UBOOT_GIT_LIST=(
      "https://source.denx.de/u-boot/u-boot.git"
      "https://mirrors.tuna.tsinghua.edu.cn/git/u-boot.git"
    )
    BUILDROOT_GIT_LIST=(
      "https://gitlab.com/buildroot.org/buildroot.git"
      "https://mirrors.tuna.tsinghua.edu.cn/git/buildroot.git"
    )
    KERNEL_TARBALL_LIST=(
      "https://cdn.kernel.org/pub/linux/kernel/v6.x"
      "https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x"
    )
    ;;
esac

# ---------- 自动挑选 defconfig / DTS ----------
# U-Boot: UBOOT_DEFCONFIG=auto 时, 先按文件名匹配 t113, 再按 defconfig 内容匹配
auto_uboot_defconfig() {
  local cfg
  if [ "${UBOOT_DEFCONFIG}" != "auto" ]; then
    echo "${UBOOT_DEFCONFIG}"
    return
  fi
  cfg="$(ls "${UBOOT_SRC}/configs" 2>/dev/null | grep -i 't113' | head -1 || true)"
  if [ -z "${cfg}" ]; then
    cfg="$(grep -rli 't113' "${UBOOT_SRC}/configs" 2>/dev/null | xargs -n1 basename 2>/dev/null | head -1 || true)"
  fi
  if [ -z "${cfg}" ]; then
    warn "configs/ 中未找到 t113 defconfig, 可选项:"
    ls "${UBOOT_SRC}/configs" | grep -iE 'mangopi|dong|sun8i' | head -20 || true
    die "请在 config/board.env 中手动设置 UBOOT_DEFCONFIG"
  fi
  echo "${cfg}"
}

# 内核: 返回上游 sun8i-t113*.dts 的名字(不含 .dts)
auto_kernel_dts() {
  local dts
  dts="$(find "${KERNEL_SRC}/arch/arm/boot/dts" -name 'sun8i-t113*.dts' ! -name '*.dtsi' 2>/dev/null | head -1 || true)"
  [ -n "${dts}" ] || die "内核树中未找到 sun8i-t113*.dts, 请在 config/board.env 手动设置 KERNEL_DTS"
  basename "${dts}" .dts
}

# ---------- SPI flash 布局 ----------
# 由 config/board.env 的 SPI_{UBOOT,DTB,KERNEL}_SIZE 推导各分区偏移
# 设置: SPI_OFF_UBOOT / SPI_OFF_DTB / SPI_OFF_KERNEL / SPI_OFF_ROOTFS / SPI_ROOTFS_SIZE
spi_layout() {
  SPI_OFF_UBOOT=0
  if [ "${SPI_FLASH_TYPE}" = "nand" ]; then
    # SPI NAND: 各分区连续排布, 偏移天然落在 128KB 擦除块边界上
    SPI_OFF_DTB=$(( SPI_UBOOT_SIZE ))
    SPI_OFF_KERNEL=$(( SPI_OFF_DTB + SPI_DTB_SIZE ))
  else
    # SPI NOR: 沿用历史布局 —— dtb 之后留一段空隙 (0x90000~0x100000),
    # U-Boot 环境变量就存在这里 (offset 0xF0000, 见 configs/uboot/t113_s3.config),
    # 所以 kernel 必须从 0x100000 开始, 不能改成紧跟 dtb 的连续排布。
    SPI_OFF_DTB=0x80000
    SPI_OFF_KERNEL=0x100000
    (( SPI_UBOOT_SIZE <= SPI_OFF_DTB )) \
      || die "SPI NOR 的 uboot 分区不能超过 0x80000 (512K), 否则会压到 dtb 分区: SPI_UBOOT_SIZE=${SPI_UBOOT_SIZE}"
    (( SPI_OFF_DTB + SPI_DTB_SIZE <= SPI_OFF_KERNEL )) \
      || die "SPI NOR 的 dtb 分区 (0x80000 + ${SPI_DTB_SIZE}) 会压到 kernel 分区 (0x100000)"
  fi
  SPI_OFF_ROOTFS=$(( SPI_OFF_KERNEL + SPI_KERNEL_SIZE ))
  SPI_ROOTFS_SIZE=$(( SPI_FLASH_SIZE_MB * 1024 * 1024 - SPI_OFF_ROOTFS ))
}

# 从板级 DTS 的 partitions 节点读出 "label 起始偏移 大小" (没有分区节点时不输出)
dts_partitions() { # $1 = dts 文件
  [ -f "$1" ] || return 0
  awk '
    /label[[:space:]]*=[[:space:]]*"/ {
      line = $0; sub(/^[^"]*"/, "", line); sub(/".*$/, "", line); label = line
    }
    /[^a-z-]reg[[:space:]]*=[[:space:]]*</ {
      line = $0; sub(/^.*</, "", line); sub(/>.*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      n = split(line, v, /[[:space:]]+/)
      if (label != "" && n >= 2) printf "%s %s %s\n", label, v[1], v[2]
    }
  ' "$1"
}

# 校验板级 DTS 的分区表与 config/board.env 推导出的布局一致
# (两者不一致时镜像会被写到错误偏移, 所以这里直接报错)
check_dts_partitions() { # $1 = dts 文件
  local dts="$1" parsed label off size exp_off exp_size
  [ -f "${dts}" ] || return 0
  parsed="$(dts_partitions "${dts}")"
  [ -n "${parsed}" ] || return 0

  while read -r label off size; do
    case "${label}" in
      uboot)  exp_off="${SPI_OFF_UBOOT}";  exp_size="${SPI_UBOOT_SIZE}"  ;;
      dtb)    exp_off="${SPI_OFF_DTB}";    exp_size="${SPI_DTB_SIZE}"    ;;
      kernel) exp_off="${SPI_OFF_KERNEL}"; exp_size="${SPI_KERNEL_SIZE}" ;;
      rootfs) exp_off="${SPI_OFF_ROOTFS}"; exp_size="${SPI_ROOTFS_SIZE}" ;;
      *)      continue ;;
    esac
    if [ "$(( off ))" != "$(( exp_off ))" ] || [ "$(( size ))" != "$(( exp_size ))" ]; then
      die "$(basename "${dts}") 的分区 '${label}' 是 $(printf '0x%x' "$(( off ))")+$(printf '0x%x' "$(( size ))") , 与 config/board.env 推出的 $(printf '0x%x' "$(( exp_off ))")+$(printf '0x%x' "$(( exp_size ))") 不一致 — 两边要一起改 (切换 SPI_FLASH_TYPE 时, board/dts 与 board/uboot-dts 里的 flash 节点和分区也要同步换)"
    fi
  done <<< "${parsed}"
}
