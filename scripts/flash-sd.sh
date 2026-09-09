#!/usr/bin/env bash
# 宿主机(macOS)烧写脚本: 把 out/images/t113-sdcard.img 写入 SD 卡
# 用法: make flash DEV=/dev/disk4
set -euo pipefail
cd "$(dirname "$0")/.."

IMG="${IMG:-out/images/t113-sdcard.img}"
DEV="${1:-${DEV:-}}"

die() { echo -e "\033[31m[error]\033[0m $*" >&2; exit 1; }
log() { echo -e "\033[32m[flash]\033[0m $*"; }

[ -f "${IMG}" ] || die "镜像不存在: ${IMG}, 先运行 make pack"
[ -n "${DEV}" ] || die "用法: make flash DEV=/dev/diskN  (diskutil list 查看设备号)"
case "${DEV}" in
  /dev/disk[0-9]*) ;;
  *) die "设备名格式应为 /dev/diskN, 收到: ${DEV}" ;;
esac
diskutil info "${DEV}" >/dev/null 2>&1 || die "设备不存在: ${DEV}"

# 防呆: 拒绝内置磁盘
INTERNAL="$(diskutil info -plist "${DEV}" >/tmp/.t113_diskinfo.plist \
  && /usr/bin/python3 -c 'import plistlib;print(plistlib.load(open("/tmp/.t113_diskinfo.plist")).get("Internal", True))')"
if [ "${INTERNAL}" = "True" ] && [ "${FORCE:-0}" != "1" ]; then
  die "${DEV} 是内置磁盘, 拒绝写入! (确认无误可用 FORCE=1 make flash DEV=${DEV})"
fi

log "即将写入 ${IMG} -> ${DEV}"
diskutil list "${DEV}"
printf "10 秒后开始, Ctrl+C 取消..."
sleep 10
echo

diskutil unmountDisk force "${DEV}"
log "dd 写入中 (使用 raw 设备, 速度更快)..."
dd if="${IMG}" of="/dev/r$(basename "${DEV}")" bs=4m conv=fsync
sync
diskutil eject "${DEV}"
log "烧写完成, SD 卡已弹出。插到 T113-S3 上电即可启动 (调试串口 UART3 @ PB6/PB7, 115200 8N1)"
