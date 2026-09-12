#!/usr/bin/env bash
# 编译 U-Boot (SPL + U-Boot), 产物: out/uboot/u-boot-sunxi-with-spl.bin
# 支持板级配置片段 configs/uboot/${CONFIG_STEM}.config 与板级 DT (UBOOT_DTS=board)
set -euo pipefail
. "$(dirname "$0")/env.sh"

[ -f "${UBOOT_SRC}/Makefile" ] || die "U-Boot 源码不存在, 先运行 make fetch"

# ---- 应用项目补丁 ----
# sources/ 不入库 (make fetch 会重新 clone), 所以对 U-Boot 的改动放在 patches/uboot/*.patch,
# 每次编译前自动应用; 已经应用过的会跳过, 不会重复打。
PATCH_DIR="${ROOT_DIR}/patches/uboot"
if [ -d "${PATCH_DIR}" ]; then
  for p in "${PATCH_DIR}"/*.patch; do
    [ -f "${p}" ] || continue
    # Windows (core.autocrlf) 检出的补丁可能是 CRLF, git apply 会当损坏补丁拒绝;
    # 检测到就先转成 LF 临时副本再应用, 不动仓库里的文件
    p_clean="${p}"
    if grep -q $'\r' "${p}"; then
      p_clean="${OUT_DIR}/$(basename "${p}").lf"
      mkdir -p "${OUT_DIR}"
      tr -d '\r' < "${p}" > "${p_clean}"
      warn "补丁含 CRLF (Windows 检出所致), 已转 LF 后应用: $(basename "${p}")"
    fi
    if git -C "${UBOOT_SRC}" apply --check --reverse "${p_clean}" >/dev/null 2>&1; then
      log "补丁已应用: $(basename "${p}")"
    elif git -C "${UBOOT_SRC}" apply --check "${p_clean}" >/dev/null 2>&1; then
      log "应用补丁: $(basename "${p}")"
      git -C "${UBOOT_SRC}" apply "${p_clean}" || die "补丁应用失败: ${p}"
    else
      die "$(basename "${p}") 既不能应用也不是已应用状态 —— U-Boot 源码可能被改过, 建议 make distclean 后重新 make fetch"
    fi
  done
fi

UBOOT_CFG="$(auto_uboot_defconfig)"
UBOOT_OUT="${OUT_DIR}/uboot"
mkdir -p "${UBOOT_OUT}"

# ---- 板级 DT: 复制进源码树并注册到 dts Makefile ----
# U-Boot DT 与内核 dtb 同名 (${BOARD_DTS_NAME}), boot.cmd 用 ${fdtfile} 引用
if [ "${UBOOT_DTS}" = "board" ]; then
  BDT_NAME="${BOARD_DTS_NAME}"
  BDT_DTS="${ROOT_DIR}/board/uboot-dts/${BDT_NAME}.dts"
  [ -f "${BDT_DTS}" ] || die "board/uboot-dts/${BDT_NAME}.dts 不存在"
  cp "${BDT_DTS}" "${UBOOT_SRC}/arch/arm/dts/${BDT_NAME}.dts"
  if ! grep -q "${BDT_NAME}\.dtb" "${UBOOT_SRC}/arch/arm/dts/Makefile"; then
    log "注册板级 DT 到 U-Boot dts Makefile"
    echo "dtb-y += ${BDT_NAME}.dtb" >> "${UBOOT_SRC}/arch/arm/dts/Makefile"
  fi
  # U-Boot 的 mtd read/write <分区名> 依赖 DT 里的 partitions 节点,
  # 分区表必须与内核 DTS / config/board.env 一致
  spi_layout
  check_dts_partitions "${BDT_DTS}"
fi

log "U-Boot defconfig: ${UBOOT_CFG}"
make -C "${UBOOT_SRC}" O="${UBOOT_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "${UBOOT_CFG}"

# ---- 合并板级配置片段 (SPI flash / 兜底启动 / 板级 DT) ----
UBOOT_FRAG="${ROOT_DIR}/configs/uboot/${CONFIG_STEM}.config"
[ -f "${UBOOT_FRAG}" ] || die "缺少 U-Boot 配置片段 ${UBOOT_FRAG}"
log "合并 U-Boot 板级配置片段 configs/uboot/${CONFIG_STEM}.config"
"${UBOOT_SRC}/scripts/kconfig/merge_config.sh" -m -O "${UBOOT_OUT}" \
    "${UBOOT_OUT}/.config" "${UBOOT_FRAG}"
make -C "${UBOOT_SRC}" O="${UBOOT_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

make -C "${UBOOT_SRC}" O="${UBOOT_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}"

require_file "${UBOOT_OUT}/u-boot-sunxi-with-spl.bin"
log "U-Boot 编译完成:"
ls -lh "${UBOOT_OUT}/u-boot-sunxi-with-spl.bin" "${UBOOT_OUT}/u-boot" 2>/dev/null || true
log "烧写位置: SD 卡 8KiB 偏移 / SPI flash 0 偏移 (make pack / make pack-spi 自动处理)"
