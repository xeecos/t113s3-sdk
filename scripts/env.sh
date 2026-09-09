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
