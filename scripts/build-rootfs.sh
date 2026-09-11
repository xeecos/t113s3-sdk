#!/usr/bin/env bash
# 组装最小根文件系统 (busybox) 并生成 out/rootfs.ext4
# 需要更完整的应用层 (dropbear/htop/wpa_supplicant 等) 时改用: make rootfs-buildroot
set -euo pipefail
. "$(dirname "$0")/env.sh"

require_file "${OUT_DIR}/busybox/busybox"

log "组装最小根文件系统 -> ${ROOTFS_DIR}"
# 注意: mke2fs -d 不支持从 virtiofs (/work, 仅 Docker Desktop 的挂载方式) 读 xattr,
# 因此在本地文件系统暂存, 只把最终 ext4 产物放回 out/ (原生构建同样走这里, 无副作用)
STAGE_DIR="/tmp/t113-rootfs"
rm -rf "${STAGE_DIR}"
ROOTFS_DIR="${STAGE_DIR}"
mkdir -p "${ROOTFS_DIR}"/{bin,sbin,etc/init.d,proc,sys,dev,pts,tmp,var/log,usr/bin,usr/sbin,lib,root,mnt,home,data}

install -m 755 "${OUT_DIR}/busybox/busybox" "${ROOTFS_DIR}/bin/busybox"

# 用 qemu-user 在主机侧列出全部 applet 并建立符号链接
QEMU_ARM="$(command -v qemu-arm-static || command -v qemu-arm || true)"
[ -n "${QEMU_ARM}" ] || die "找不到 qemu-arm(-static), 无法生成 applet 链接"
APPLETS="$("${QEMU_ARM}" "${ROOTFS_DIR}/bin/busybox" --list)"
for a in ${APPLETS}; do
  [ -e "${ROOTFS_DIR}/bin/${a}" ] || ln -s busybox "${ROOTFS_DIR}/bin/${a}"
done
ln -sf ../bin/busybox "${ROOTFS_DIR}/sbin/init"

# ---- 用户应用 (apps/): 交叉编译后装入 /usr/bin ----
bash "$(dirname "$0")/build-apps.sh"
for adir in "${OUT_DIR}"/apps/*/; do
  [ -d "${adir}" ] || continue
  name="$(basename "${adir}")"
  install -m 755 "${adir}/${name}" "${ROOTFS_DIR}/usr/bin/${name}"
  log "装入应用: /usr/bin/${name}"
done

# ---- /etc ----
cat > "${ROOTFS_DIR}/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS
ttyS3::askfirst:-/bin/sh
::restart:/sbin/init
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

cat > "${ROOTFS_DIR}/etc/init.d/rcS" <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts
hostname t113-s3
echo
echo "Welcome to T113-S3 (busybox minimal rootfs)"
echo

# ---- 全 flash 模式 (root=/dev/mtdblock3, SPI NOR 或 SPI NAND 都是这个根设备):
#      SD 卡 p1 作为用户数据盘 -> /data
# SD 启动模式 (/dev/mmcblk0p2 是系统盘) 不挂载, 避免误挂系统分区
if grep -q mtdblock /proc/cmdline; then
  if [ -b /dev/mmcblk0 ]; then
    i=0
    while [ $i -lt 20 ] && [ ! -b /dev/mmcblk0p1 ]; do i=$((i + 1)); sleep 0.1; done
    if [ -b /dev/mmcblk0p1 ] && mount /dev/mmcblk0p1 /data 2>/dev/null; then
      echo "SD user data (/dev/mmcblk0p1) mounted at /data"
    else
      echo "SD present but no mountable p1 partition (mkfs.ext4/vfat first?)"
    fi
  fi
fi
EOF
chmod 755 "${ROOTFS_DIR}/etc/init.d/rcS"

cat > "${ROOTFS_DIR}/etc/fstab" <<'EOF'
proc            /proc   proc    defaults        0 0
sysfs           /sys    sysfs   defaults        0 0
devtmpfs        /dev    devtmpfs defaults        0 0
EOF

cat > "${ROOTFS_DIR}/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
cat > "${ROOTFS_DIR}/etc/group" <<'EOF'
root:x:0:
EOF
echo "t113-s3" > "${ROOTFS_DIR}/etc/hostname"
chmod 1777 "${ROOTFS_DIR}/tmp"

# ---- 打包 ext4 ----
ROOTFS_IMG="${OUT_DIR}/rootfs.ext4"
rm -f "${ROOTFS_IMG}" /tmp/t113-rootfs.ext4
log "生成 ${ROOTFS_IMG} (${ROOTFS_SIZE_MB}M)"
mke2fs -F -q -t ext4 -L rootfs -b 4096 \
    -d "${ROOTFS_DIR}" /tmp/t113-rootfs.ext4 "${ROOTFS_SIZE_MB}M"
mv /tmp/t113-rootfs.ext4 "${ROOTFS_IMG}"
log "rootfs 完成: $(ls -lh "${ROOTFS_IMG}" | awk '{print $5, $9}')"
