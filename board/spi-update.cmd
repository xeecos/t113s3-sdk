# SPI Flash 更新脚本 (U-Boot 下运行)
# 用途: 从 SD 卡 boot 分区 (FAT32) 读取 zImage/dtb, 烧入 SPI flash
#
# 用法: 插入本环境打出的 SD 卡, U-Boot 命令行执行:
#   mmc dev 0
#   fatload mmc 0:1 ${scriptaddr} spi-update.scr
#   source ${scriptaddr}
#
# SPI flash 布局 (scripts/pack-spi.sh 一致):
#   0x000000  U-Boot (不在此更新, 见 README "更新 U-Boot")
#   0x080000  dtb      (64K)
#   0x100000  zImage   (12M)
#   0xD00000  rootfs.squashfs (SPI_ROOTFS=1 时)

sf probe

# ---- 更新 dtb ----
fatload mmc 0:1 ${fdt_addr_r} ${fdtfile}
sf erase 0x80000 0x10000
sf write ${fdt_addr_r} 0x80000 ${filesize}

# ---- 更新 zImage ----
fatload mmc 0:1 ${kernel_addr_r} zImage
sf erase 0x100000 0xC00000
sf write ${kernel_addr_r} 0x100000 ${filesize}

# ---- (可选) 更新 SPI 里的 squashfs rootfs ----
# 先把 rootfs.squashfs 拷到 SD 卡 boot 分区, 再取消注释 (容量按 flash 大小调整):
# fatload mmc 0:1 ${ramdisk_addr_r} rootfs.squashfs
# sf erase 0xD00000 ${filesize}
# sf write ${ramdisk_addr_r} 0xD00000 ${filesize}

echo "SPI flash 更新完成"
