#!/usr/bin/env bash
# 拉取 U-Boot (git) / busybox (tarball) / Linux (tarball) 源码
set -euo pipefail
. "$(dirname "$0")/env.sh"

# 克隆停滞探测: 国内镜像偶尔连得上但不再传数据, 不盯着就会一直挂着。
# 每 GIT_STALL_INTERVAL 秒看一次目标目录体积, 连续 GIT_STALL_PROBES 次不增长即放弃该镜像。
GIT_STALL_PROBES="${GIT_STALL_PROBES:-6}"
GIT_STALL_INTERVAL="${GIT_STALL_INTERVAL:-30}"

clone_one() { # $1=url $2=ref $3=目录
  local url="$1" ref="$2" dir="$3" prev="" cur i=0 pid rc=0
  git clone --depth 1 --branch "${ref}" "${url}" "${dir}" &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    sleep "${GIT_STALL_INTERVAL}"
    kill -0 "${pid}" 2>/dev/null || break
    cur="$(du -sk "${dir}" 2>/dev/null | cut -f1)"
    cur="${cur:-0}"
    if [ "${cur}" = "${prev}" ]; then
      i=$((i + 1))
      if [ "${i}" -ge "${GIT_STALL_PROBES}" ]; then
        warn "克隆停滞 $((i * GIT_STALL_INTERVAL))s 无任何数据增长, 放弃 ${url}"
        kill -TERM "${pid}" 2>/dev/null || true
        sleep 2
        kill -KILL "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        return 1
      fi
    else
      i=0
    fi
    prev="${cur}"
  done
  wait "${pid}" || rc=$?
  [ "${rc}" -eq 0 ]
}

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
    if clone_one "${url}" "${ref}" "${dir}"; then
      return 0
    fi
    warn "该镜像未成功 (失败/停滞), 换下一个..."
    rm -rf "${dir}"
  done
  die "所有镜像均克隆失败 (ref=${ref})。请检查网络, 或用 MIRROR=official 换源"
}

# ---- 1. U-Boot ----
fetch_git "${UBOOT_SRC}" "${UBOOT_REF}" "${UBOOT_GIT_LIST[@]}"
# 大小写不敏感的文件系统 (WSL 里的 /mnt/d) 上 checkout 会静默丢文件, 核对一次
case_dups_of_git "${UBOOT_SRC}" > "${DL_DIR}/uboot.case-dups"
case_dup_verify "${UBOOT_SRC}" "${DL_DIR}/uboot.case-dups"

# ---- 2. busybox ----
BZ_TARBALL="busybox-${BUSYBOX_REF}.tar.bz2"
BZ_DUPS="${DL_DIR}/${BZ_TARBALL}.case-dups"
if [ ! -f "${BUSYBOX_SRC}/Makefile" ]; then
  log "下载 busybox ${BUSYBOX_REF}"
  wget -q --show-progress --timeout=60 -O "${DL_DIR}/${BZ_TARBALL}" \
      "https://busybox.net/downloads/${BZ_TARBALL}" \
    || wget -q --timeout=60 -O "${DL_DIR}/${BZ_TARBALL}" \
      "http://sources.buildroot.net/busybox/${BZ_TARBALL}" \
    || die "busybox 下载失败, 可手动放置 ${DL_DIR}/${BZ_TARBALL}"
  # 解压前先记录"仅大小写不同"的文件名, 解压后再核对是否真的都在
  case_dups_of_tarball "${DL_DIR}/${BZ_TARBALL}" j > "${BZ_DUPS}"
  tar -xjmf "${DL_DIR}/${BZ_TARBALL}" -C "${SRC_DIR}" --no-same-owner
  mv "${SRC_DIR}/busybox-${BUSYBOX_REF}" "${BUSYBOX_SRC}"
else
  log "busybox 已存在, 跳过"
  if [ -f "${DL_DIR}/${BZ_TARBALL}" ]; then
    case_dups_of_tarball "${DL_DIR}/${BZ_TARBALL}" j > "${BZ_DUPS}"
  fi
fi
case_dup_verify "${BUSYBOX_SRC}" "${BZ_DUPS}"

# ---- 3. Linux (tarball, 比 git clone 快且不易被网络干扰) ----
K_TARBALL="linux-${KERNEL_VER}.tar.xz"
K_DUPS="${DL_DIR}/${K_TARBALL}.case-dups"
if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
  log "下载内核 ${K_TARBALL} (~140M)"
  ok=0
  for base in "${KERNEL_TARBALL_LIST[@]}"; do
    if wget -q --show-progress -c --timeout=60 -O "${DL_DIR}/${K_TARBALL}" "${base}/${K_TARBALL}"; then ok=1; break; fi
    warn "下载失败: ${base}/${K_TARBALL}, 尝试下一个镜像..."
    rm -f "${DL_DIR}/${K_TARBALL}"
  done
  [ "${ok}" = 1 ] || die "内核下载失败, 可手动放置 ${DL_DIR}/${K_TARBALL}"
  log "解压内核源码..."
  # --no-same-owner/-m: virtiofs 挂载不允许 chown/utime, 且对构建无影响
  case_dups_of_tarball "${DL_DIR}/${K_TARBALL}" J > "${K_DUPS}"
  tar -xJmf "${DL_DIR}/${K_TARBALL}" -C "${SRC_DIR}" --no-same-owner
  mv "${SRC_DIR}/linux-${KERNEL_VER}" "${KERNEL_SRC}"
else
  log "linux 已存在, 跳过"
  if [ -f "${DL_DIR}/${K_TARBALL}" ]; then
    case_dups_of_tarball "${DL_DIR}/${K_TARBALL}" J > "${K_DUPS}"
  fi
fi
# 内核树里这类文件很多 (netfilter uapi 的 xt_*.h), 落到大小写不敏感的文件系统上必丢
case_dup_verify "${KERNEL_SRC}" "${K_DUPS}"

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
