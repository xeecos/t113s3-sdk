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

# 并行任务数: make JOBS=8 或 JOBS=8 bash scripts/build-kernel.sh 可覆盖
# (默认 nproc; WSL 里 CPU 给得多但内存有限时, 全核并行的内核编译容易 OOM)
JOBS="${JOBS:-$(nproc)}"

# ---------- 大小写不敏感文件系统的防护 ----------
# 源码树里存在仅大小写不同的文件名 (内核 include/uapi/linux/netfilter/ 下就有
# xt_CONNMARK.h 与 xt_connmark.h, xt_MARK.h 与 xt_mark.h 等)。在大小写不敏感的
# 文件系统上 (WSL 挂载的 Windows 盘 /mnt/d), 解压/检出时它们会落成同一个文件,
# 悄悄少掉一个, 之后表现为"莫名缺少头文件"之类的怪错误。
# 做法: 解压/克隆前先取出冲突名单, 完成后逐个核对目录里的真实文件名。

# 目录所在文件系统是否大小写不敏感 (建两个仅大小写不同的临时文件来探)
fs_case_insensitive() { # $1=目录
  local a="$1/.t113-CaseProbe.$$" b="$1/.t113-caseprobe.$$"
  : > "${a}" 2>/dev/null || return 1
  if [ -e "${b}" ]; then
    rm -f "${a}" "${b}"
    return 0
  fi
  rm -f "${a}"
  return 1
}

# 冲突名单 —— 只有大小写不敏感的文件系统才需要算 (大小写敏感时输出空名单, 不影响性能)
case_dups_of_tarball() { # $1=压缩包 $2=tar 压缩选项 (J=xz, j=bz2)
  fs_case_insensitive "${SRC_DIR}" || return 0
  tar -t"$2"f "$1" 2>/dev/null | grep -v '/$' | sed 's|^[^/]*/||' \
    | LC_ALL=C sort -f | LC_ALL=C uniq -Di
}

case_dups_of_git() { # $1=git 仓库目录
  fs_case_insensitive "${SRC_DIR}" || return 0
  git -C "$1" ls-tree -r --name-only HEAD 2>/dev/null \
    | LC_ALL=C sort -f | LC_ALL=C uniq -Di
}

# 核对解压/检出结果: $1=源码根目录 $2=冲突名单文件 (名单为空或不存在则跳过)
# 注意: 不能直接用 [ -e ] 判断 —— 在大小写不敏感的文件系统上两个名字都"存在",
# 只有比对目录里的真实文件名才能发现被覆盖丢失的那个。
case_dup_verify() {
  local root="$1" list="$2" name dir base lost=""
  [ -s "${list}" ] || return 0
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    dir="$(dirname "${name}")"; base="$(basename "${name}")"
    ls -1 "${root}/${dir}" 2>/dev/null | grep -qxF "${base}" || lost="${lost}  ${name}"
  done < "${list}"
  if [ -z "${lost}" ]; then
    return 0
  fi
  warn "文件系统大小写不敏感, 这些文件在解压/检出时被同名的(仅大小写不同)文件覆盖丢失了:"
  printf '%s\n' "${lost}"
  if [ "${ALLOW_CASE_INSENSITIVE:-0}" = 1 ]; then
    warn "ALLOW_CASE_INSENSITIVE=1: 继续 (编译可能因缺文件失败)"
    return 0
  fi
  die "把项目放到大小写敏感的文件系统上重试: WSL 里推荐 cd ~ && git clone <仓库> (见 docs/windows.md)"
}

# ---------- 源码仓库 (按 MIRROR 选择) ----------
# git 源统一用 GitHub 官方镜像 (gitee.com/mirrors 已不可用; 清华镜像站只镜像了
# kernel tarball 目录, 没有 git 服务 —— mirrors.tuna.tsinghua.edu.cn/git/... 一律 404),
# 官方源作为兜底。任一镜像克隆停滞会自动换下一个 (见 fetch-sources.sh 的停滞探测)。
# GitHub 在国内通常要挂代理: make proxy-hint 拿到地址后
#   PROXY=http://<宿主网关>:7890 make fetch
case "${MIRROR}" in
  cn)
    UBOOT_GIT_LIST=(
      "https://github.com/u-boot/u-boot.git"
      "https://source.denx.de/u-boot/u-boot.git"
    )
    BUILDROOT_GIT_LIST=(
      "https://github.com/buildroot/buildroot.git"
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
      "https://github.com/u-boot/u-boot.git"
    )
    BUILDROOT_GIT_LIST=(
      "https://gitlab.com/buildroot.org/buildroot.git"
      "https://github.com/buildroot/buildroot.git"
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
