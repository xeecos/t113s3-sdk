#!/usr/bin/env bash
# 编译内核 (zImage + dtb), 产物: out/images/zImage 与 out/images/*.dtb
set -euo pipefail
. "$(dirname "$0")/env.sh"

[ -f "${KERNEL_SRC}/Makefile" ] || die "内核源码不存在, 先运行 make fetch"

KOUT="${OUT_DIR}/kernel"
DTS_DIR="${KERNEL_SRC}/arch/arm/boot/dts"
mkdir -p "${KOUT}"
kmake() { make -C "${KERNEL_SRC}" O="${KOUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "$@"; }

# ---- 1. defconfig + 板级增量配置 ----
log "内核 defconfig: ${KERNEL_DEFCONFIG}"
kmake "${KERNEL_DEFCONFIG}"
KERNEL_FRAG="${ROOT_DIR}/configs/kernel/${CONFIG_STEM}.config"
[ -f "${KERNEL_FRAG}" ] || die "缺少内核配置片段 ${KERNEL_FRAG}"
log "合并板级配置片段 configs/kernel/${CONFIG_STEM}.config"
"${KERNEL_SRC}/scripts/kconfig/merge_config.sh" -m -O "${KOUT}" \
    "${KOUT}/.config" "${KERNEL_FRAG}"
kmake olddefconfig

# ---- 2. 确定 DTS ----
# auto  : 使用上游 T113 参考板 DTS
# board : 把 board/dts/ 下同名模板复制进内核树
# 其他  : 视为内核树内已有 DTS 名
case "${KERNEL_DTS}" in
  auto)
    DTS_NAME="$(auto_kernel_dts)"
    ;;
  board)
    DTS_NAME="${BOARD_DTS_NAME}"
    [ -f "${ROOT_DIR}/board/dts/${DTS_NAME}.dts" ] \
      || die "board/dts/${DTS_NAME}.dts 不存在, 请创建你的板级 DTS"
    inc="$(grep -oP '(?<=#include ")[^"]+\.dtsi' "${ROOT_DIR}/board/dts/${DTS_NAME}.dts" | head -1 || true)"
    if [ -n "${inc}" ] && ! find "${DTS_DIR}" -name "${inc}" | grep -q .; then
      warn "板级 DTS 引用的 ${inc} 在内核树中不存在, 实际文件名可能是:"
      find "${DTS_DIR}" -name 'sun8i-t113*.dtsi' -printf '%f\n' || true
      warn "请修改 board/dts/${DTS_NAME}.dts 的 #include 后重试"
    fi
    cp "${ROOT_DIR}/board/dts/${DTS_NAME}.dts" "${DTS_DIR}/allwinner/"
    # 注册到 dtb 构建列表 (6.x 内核 dtbs 只编译 Makefile 里列出的文件)
    if ! grep -q "${DTS_NAME}\.dtb" "${DTS_DIR}/allwinner/Makefile"; then
      echo "dtb-y += ${DTS_NAME}.dtb" >> "${DTS_DIR}/allwinner/Makefile"
    fi
    ;;
  *)
    DTS_NAME="${KERNEL_DTS}"
    find "${DTS_DIR}" -name "${DTS_NAME}.dts" | grep -q . \
      || die "内核树中不存在 ${DTS_NAME}.dts"
    ;;
esac
log "使用 DTS: ${DTS_NAME}"

# ---- 3. 编译 ----
# 注: 6.x 后期内核 dts 移入厂商子目录, 单个 dtb 目标不能从顶层直呼, 统一用 dtbs
kmake -j"${JOBS}" zImage
kmake -j"${JOBS}" dtbs

# ---- 4. 收集产物 (统一命名为 ${BOARD_DTS_NAME}.dtb, boot.scr 用 ${fdtfile} 引用) ----
DTB_PATH="$(find "${KOUT}/arch/arm/boot/dts" -name "${DTS_NAME}.dtb" | head -1)"
require_file "${KOUT}/arch/arm/boot/zImage"
[ -n "${DTB_PATH}" ] || die "未找到 ${DTS_NAME}.dtb"
cp "${KOUT}/arch/arm/boot/zImage" "${IMG_DIR}/zImage"
cp "${DTB_PATH}" "${IMG_DIR}/"
cp "${DTB_PATH}" "${IMG_DIR}/${BOARD_DTS_NAME}.dtb"

log "内核编译完成:"
ls -lh "${IMG_DIR}"
