# T113-S3 SD 卡启动脚本 (由 mkimage 转成 boot.scr 放到 boot 分区)
# 内核从 p1 (FAT32) 加载, 根文件系统在 p2 (ext4)
# 调试串口: UART3 @ PB6/PB7 -> ttyS3 (T113-S3 SiP 封装)

setenv bootargs console=ttyS3,115200 root=/dev/mmcblk0p2 rootwait panic=10 loglevel=7

load mmc 0:1 ${kernel_addr_r} zImage
load mmc 0:1 ${fdt_addr_r} ${fdtfile}

bootz ${kernel_addr_r} - ${fdt_addr_r}

# 启动失败时回到 u-boot 命令行
echo "boot failed, dropping to u-boot shell"
