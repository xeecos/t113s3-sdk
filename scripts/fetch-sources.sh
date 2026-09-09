#!/usr/bin/env bash
# 拉取 U-Boot (git) / busybox (tarball) / Linux (tarball) 源码
set -euo pipefail
. "$(dirname "$0")/env.sh"

fetch_git() {
  local dir="$1" ref="$2"
  shift 2
  local urls=("$@")
  if [ -d "${dir}/.git" ]; then
    log "$(basename "${dir}") 已存在, 跳过"
    return 0
  fi
  local url
  for url in "${urls[@]}"; do
    log "git clone --depth 1 --branch ${ref} ${url}"
    if git clone --depth 1 --branch "${ref}" "${url}" "${dir}"; then
      return 0
    fi
    warn "克隆失败, 尝试下一个镜像..."
    rm -rf "${dir}"
  done
  die "所有镜像均克隆失败 (ref=${ref})。请检查网络, 或修改 config/board.env / MIRROR"
}

# ---- 1. U-Boot ----
fetch_git "${UBOOT_SRC}" "${UBOOT_REF}" "${UBOOT_GIT_LIST[@]}"

# ---- 2. busybox ----
BZ_TARBALL="busybox-${BUSYBOX_REF}.tar.bz2"
if [ ! -f "${BUSYBOX_SRC}/Makefile" ]; then
  log "下载 busybox ${BUSYBOX_REF}"
  wget -q --show-progress -O "${DL_DIR}/${BZ_TARBALL}" \
      "https://busybox.net/downloads/${BZ_TARBALL}" \
    || wget -q -O "${DL_DIR}/${BZ_TARBALL}" \
      "http://sources.buildroot.net/busybox/${BZ_TARBALL}" \
    || die "busybox 下载失败, 可手动放置 ${DL_DIR}/${BZ_TARBALL}"
  tar -xjmf "${DL_DIR}/${BZ_TARBALL}" -C "${SRC_DIR}" --no-same-owner
  mv "${SRC_DIR}/busybox-${BUSYBOX_REF}" "${BUSYBOX_SRC}"
else
  log "busybox 已存在, 跳过"
fi

# ---- 3. Linux (tarball, 比 git clone 快且不易被网络干扰) ----
K_TARBALL="linux-${KERNEL_VER}.tar.xz"
if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
  log "下载内核 ${K_TARBALL} (~140M)"
  ok=0
  for base in "${KERNEL_TARBALL_LIST[@]}"; do
    if wget -q --show-progress -c -O "${DL_DIR}/${K_TARBALL}" "${base}/${K_TARBALL}"; then ok=1; break; fi
    warn "下载失败: ${base}/${K_TARBALL}, 尝试下一个镜像..."
    rm -f "${DL_DIR}/${K_TARBALL}"
  done
  [ "${ok}" = 1 ] || die "内核下载失败, 可手动放置 ${DL_DIR}/${K_TARBALL}"
  log "解压内核源码..."
  # --no-same-owner/-m: virtiofs 挂载不允许 chown/utime, 且对构建无影响
  tar -xJmf "${DL_DIR}/${K_TARBALL}" -C "${SRC_DIR}" --no-same-owner
  mv "${SRC_DIR}/linux-${KERNEL_VER}" "${KERNEL_SRC}"
else
  log "linux 已存在, 跳过"
fi

# ---- 信息汇总: 帮助用户确认可用的板级选项 ----
echo
log "源码就绪: $(ls "${SRC_DIR}" | tr '\n' ' ')"
echo
log "可用的 T113 相关 U-Boot defconfig:"
find "${UBOOT_SRC}/configs" -maxdepth 1 -name '*_defconfig' | xargs -n1 basename | grep -i t113 || warn "(无)"
echo
log "可用的 T113 相关内核 DTS:"
find "${KERNEL_SRC}/arch/arm/boot/dts" \( -name 'sun8i-t113*.dts' -o -name 'sun8i-t113*.dtsi' \) ! -name '*.dtsi' -printf '%f\n' 2>/dev/null | sort
ls "${KERNEL_SRC}/arch/arm/boot/dts/allwinner/" 2>/dev/null | grep -E '^sun8i-t113.*\.dtsi$' || true
