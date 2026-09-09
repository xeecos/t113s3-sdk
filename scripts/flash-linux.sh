#!/usr/bin/env bash
# 宿主机 Linux / WSL2 烧写脚本: 把 out/images/t113-sdcard.img 写入 SD 卡
# 用法: make flash DEV=/dev/sdX        (sudo 会自动提权)
#   WSL2 需先把 SD 读卡器用 usbipd 透传给 WSL (见 docs/windows.md),
#   设备名用 `lsblk` 查看; Windows 上勿直接跑本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."

IMG="${IMG:-out/images/t113-sdcard.img}"
DEV="${1:-${DEV:-}}"

die() { echo -e "\033[31m[error]\033[0m $*" >&2; exit 1; }
log() { echo -e "\033[32m[flash]\033[0m $*"; }

# 写裸设备需要 root: 未用 root 运行时自动 sudo 重跑
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[33m[flash]\033[0m 需要 root 权限, 自动用 sudo 重新执行..."
  exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
fi

[ -f "${IMG}" ] || die "镜像不存在: ${IMG}, 先运行 make pack"
[ -n "${DEV}" ] || die "用法: make flash DEV=/dev/sdX  (lsblk 查看设备号)"
[ -b "${DEV}" ] || die "${DEV} 不是块设备"

BASE="$(basename "${DEV}")"

# 防呆 1: 只接受整盘设备, 拒绝分区 (分区名通常带数字后缀)
case "${BASE}" in
  sd[a-z] | mmcblk[0-9] | nvme[0-9]n[0-9]) ;;
  *)
    lsblk -o NAME,SIZE,TYPE "${DEV}"
    die "${DEV} 看起来是分区而非整盘。请填整卡设备 (如 /dev/sda、/dev/mmcblk0); 确认无误可用 FORCE=1 绕过"
    ;;
esac

# 防呆 2: 拒绝内置磁盘 (removable=1 才允许; FORCE=1 绕过)
REMOVABLE="$(cat "/sys/class/block/${BASE}/removable" 2>/dev/null || echo 0)"
if [ "${REMOVABLE}" != "1" ] && [ "${FORCE:-0}" != "1" ]; then
  lsblk -o NAME,SIZE,TYPE,TRAN,MODEL "${DEV}"
  die "${DEV} 不是可移动设备, 拒绝写入! (确认无误用 FORCE=1 make flash DEV=${DEV})"
fi

# 防呆 3: 拒绝已挂载的设备 (先卸载再烧)
if grep -qs "${DEV}" /proc/mounts; then
  die "${DEV} 已被挂载, 请先卸载: sudo umount ${DEV}?*  (或拔出重插)"
fi

# 防呆 4: 容量检查, 镜像必须小于目标卡
IMGSZ="$(stat -c%s "${IMG}")"
DEVSZ="$(blockdev --getsize64 "${DEV}")"
[ "${IMGSZ}" -le "${DEVSZ}" ] || die "镜像 (${IMGSZ} B) 大于设备 (${DEVSZ} B), 卡太小或选错设备"

log "即将写入 ${IMG} -> ${DEV} ($((DEVSZ / 1024 / 1024)) MB 卡)"
lsblk -o NAME,SIZE,TYPE,MODEL "${DEV}"
printf "10 秒后开始, Ctrl+C 取消..."
sleep 10
echo

# WSL2 里设备可能被自动挂载出小分区, 再次检查后直接写入
dd if="${IMG}" of="${DEV}" bs=4M conv=fsync status=progress
sync
log "烧写完成。插到 T113-S3 上电即可启动 (调试串口 UART3 @ PB6/PB7, 115200 8N1)"

# WSL2 提示回收 USB 设备
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo -e "\033[32m[flash]\033[0m WSL2 环境: 回到 Windows 执行 usbipd detach 即可弹出读卡器"
fi
