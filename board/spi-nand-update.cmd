# SPI NAND 更新脚本 (U-Boot 下运行)
# 用途: 从 SD 卡 boot 分区 (FAT32) 读取 zImage/dtb/rootfs.squashfs, 写入 SPI NAND
#
# 用法: 插入本环境打出的 SD 卡, U-Boot 命令行执行:
#   mmc dev 0
#   fatload mmc 0:1 ${scriptaddr} spi-nand-update.scr
#   source ${scriptaddr}
#
# 分区名 (uboot/dtb/kernel/rootfs) 来自板级 DT 的 partitions 节点, 与内核共用,
# 所以本脚本不写死偏移; 布局定义见 scripts/pack-spi.sh
#
# 为什么不用 dd/直接写: NAND 必须经 MTD 层写 (mtd write), OOB/ECC 才由驱动生成,
# 坏块也会被自动跳过。mtd write 不指定长度时会写满整个分区, 所以必须写 ${filesize}。

mtd list

# ---- 更新 dtb ----
fatload mmc 0:1 ${fdt_addr_r} ${fdtfile}
mtd erase dtb
mtd write dtb ${fdt_addr_r} 0 ${filesize}

# ---- 更新 zImage ----
fatload mmc 0:1 ${kernel_addr_r} zImage
mtd erase kernel
mtd write kernel ${kernel_addr_r} 0 ${filesize}

# ---- (可选) 更新 SPI NAND 里的 squashfs rootfs ----
# 先把 rootfs.squashfs 拷到 SD 卡 boot 分区, 再取消下面注释 (256M flash 上约 238M):
# fatload mmc 0:1 ${ramdisk_addr_r} rootfs.squashfs
# mtd erase rootfs
# mtd write rootfs ${ramdisk_addr_r} 0 ${filesize}

# ---- (可选, 首次给空片烧写 / 换 U-Boot 时必做) 更新 uboot 分区 ----
# uboot 分区 = SPL + U-Boot proper, 是"不用 SD 卡也能启动"的关键:
# 这一块没烧或坏了, 就只能靠 SD 卡启动。文件由 make pack 放进 SD 卡 boot 分区。
# 注意: 会先擦掉正在用来启动的这一块 (U-Boot 已在内存里跑, 擦写过程本身安全),
# 但中途断电会导致 flash 无法启动 —— 此时插 SD 卡仍可从卡启动, 再重跑本脚本。
# fatload mmc 0:1 ${loadaddr} u-boot-sunxi-with-spl.bin
# mtd erase uboot
# mtd write uboot ${loadaddr} 0 ${filesize}

echo "SPI NAND 更新完成 (reset 后从 NAND 启动)"
