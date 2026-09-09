# T113-S3 Docker 编译环境

基于 Docker 的一站式 [Allwinner T113-S3](https://linux-sunxi.org/T113-s3) / [MangoPi MQ Dual](https://mangopi.org/mangopi_mq) 编译环境
(T113-i 同 die, 可直接复用): 主线 U-Boot + 主线 Linux (6.6 LTS) + busybox/Buildroot
根文件系统, 一条命令打出可启动的 SD 卡镜像与 SPI NOR 镜像, 并附带 macOS 烧写脚本。

> 适配 Apple Silicon / Intel Mac (colima 或 Docker Desktop 均可), 同样适用于
> Linux / Windows(WSL2) 上的 Docker。需要编译全志**官方 SDK** (Longan/Tina, 仅
> 支持 x86_64) 的见 [docs/vendor-sdk.md](docs/vendor-sdk.md)。

## 环境要求

| 组件 | 说明 |
|------|------|
| Docker | macOS 推荐 [colima](https://github.com/abiosoft/colima) + `brew install docker docker-compose` |
| 磁盘 | ≥ 30 GB 空闲 (源码 ~2 GB + 编译产物 ~5 GB, 镜像另有余量) |
| 网络 | 拉取源码; 国内网络已内置 TUNA/Gitee 镜像 (`MIRROR=cn`) |

colima 用户建议给足资源 (宿主 8 核 16G 为例):

```bash
colima start --cpu 6 --memory 10 --disk 80
```

## 快速开始

```bash
make image          # 1. 构建 Docker 编译镜像 (首次, 约 5 分钟)
make all            # 2. 拉源码 + 编译 uboot/内核/busybox/rootfs + 打包镜像
                    #    (内核编译约 15~40 分钟, 视机器而定)
make flash DEV=/dev/disk4   # 3. 插入 SD 卡, 烧写 (diskutil list 查设备号)
```

SD 卡插到 T113-S3 上电启动, 调试串口 **UART3 (PB6/PB7), 115200 8N1**:

```
Welcome to T113-S3 (busybox minimal rootfs)
/ #
```

> T113-S3 是 SiP 封装, PB8/PB9 被内部占用, 调试口固定为 UART3 (ttyS3),
> bootargs/设备树/rootfs 控制台已全部按此配置。

也可以手动分步执行:

```bash
make shell          # 进入容器
make fetch          # 拉取 U-Boot / Linux / busybox 源码
make uboot          # 编译 U-Boot  -> out/uboot/
make kernel         # 编译内核    -> out/images/zImage + *.dtb
make busybox        # 编译 busybox -> out/busybox/
make rootfs         # 组装根文件系统 -> out/rootfs.ext4
make pack           # 打包 SD 镜像 -> out/images/t113-sdcard.img
make pack-spi       # 打包 SPI NOR 镜像 -> out/images/t113-spi.img
```

## 目录结构

```
t113-sdk/
├── Makefile                 # 所有操作入口
├── docker-compose.yml       # 容器编排 (工作目录挂载到 /work)
├── docker/
│   ├── Dockerfile           # 编译镜像: armhf 交叉工具链 + dtc/mkimage/mtools/mtd-utils...
│   └── entrypoint.sh
├── config/
│   └── board.env            # ★ 板级配置: 工具链/源码版本/defconfig/DTS/SPI 布局
├── configs/
│   ├── kernel/t113_s3.config   # 内核增量配置 (合并到 defconfig)
│   ├── uboot/t113_s3.config    # U-Boot 增量配置 (SPI flash + 兜底启动 + 板级 DT)
│   └── buildroot/t113_s3_defconfig
├── board/
│   ├── boot.cmd             # U-Boot 启动脚本 (→ boot.scr)
│   ├── spi-update.cmd       # SD 卡 → SPI flash 更新脚本 (→ spi-update.scr)
│   ├── dts/sun8i-t113-s3.dts      # 内核板级 DTS 模板 (按硬件修改)
│   └── uboot-dts/sun8i-t113-s3.dts # U-Boot 板级 DTS (与内核 dtb 同名)
├── scripts/                 # 容器内编译脚本 + 宿主机烧写脚本
├── sources/                 # 拉取的源码 (make fetch 后出现)
├── out/                     # 全部编译产物
│   ├── images/t113-sdcard.img   # SD 卡镜像
│   ├── images/t113-spi.img      # SPI NOR 镜像
│   └── ...
└── docs/vendor-sdk.md       # 全志官方 SDK (Longan/Tina) 的 Docker 用法
```

## 板级适配 (换成你的 T113-S3 板子)

1. **U-Boot**: `config/board.env` 里 `UBOOT_DEFCONFIG=auto` 会自动选源码中含
   `t113` 的 defconfig (当前命中 MangoPi MQ-R, T113-S3 参考板)。
   `make fetch` 后可用 `ls sources/uboot/configs | grep -i t113` 查看可选项。
2. **设备树**: 模板已就绪, 按引脚/外设修改 `board/dts/sun8i-t113-s3.dts`
   (内核) 与 `board/uboot-dts/sun8i-t113-s3.dts` (U-Boot), 然后:
   - `KERNEL_DTS=board make kernel`   (或改 board.env 默认值)
   - `UBOOT_DTS=board make uboot`     (默认已是 board)
   - U-Boot/内核 dtb 同名 (`${BOARD_DTS_NAME}.dtb`), boot.cmd 用 `${fdtfile}` 引用
3. **内核配置**: 基础 `KERNEL_DEFCONFIG=multi_v7_defconfig` + 增量
   `configs/kernel/t113_s3.config`。menuconfig:
   `make -C sources/linux O=out/kernel ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- menuconfig`
4. **根文件系统**:
   - `make rootfs` — busybox 最小系统 (默认, 快)
   - `make rootfs-buildroot` — Buildroot 完整系统 (dropbear/htop 等在
     `configs/buildroot/t113_s3_defconfig` 里增删)

## SD 卡镜像布局

| 位置 | 内容 |
|------|------|
| 0 ~ 8KiB | 保留 (分区表) |
| 8KiB | `u-boot-sunxi-with-spl.bin` (BootROM 从这里引导) |
| p1: 8MiB~136MiB | FAT32: `boot.scr` / `zImage` / `sun8i-t113-s3.dtb` / `spi-update.scr` |
| p2: 136MiB~ | ext4 根文件系统 (`/dev/mmcblk0p2`) |

启动参数由 `board/boot.cmd` 控制 (console=ttyS3, root=/dev/mmcblk0p2)。

## SPI Flash 支持

T113-S3 的 SPI0 (PC2~PC5) 已全线打通: 内核 (MTD + SPI-NOR, `/dev/mtd*`)、
U-Boot (`sf probe/read/write/erase`)、镜像打包与 SD 卡一键更新脚本。

### 布局 (16M NOR 为例, 可改 SPI_FLASH_SIZE_MB=32)

| 偏移 | 大小 | 内容 |
|------|------|------|
| 0x000000 | 512K | U-Boot (SPL + U-Boot, BootROM 从 0 地址引导) |
| 0x080000 | 64K  | 设备树 `sun8i-t113-s3.dtb` |
| 0x100000 | 10M  | `zImage` |
| 0xB00000 | 剩余 | `rootfs.squashfs` (可选, `SPI_ROOTFS=1`) |

```bash
make pack-spi                       # 生成 out/images/t113-spi.img + spi-update.scr
SPI_ROOTFS=1 make pack-spi          # 全 NOR: 连 squashfs 只读 rootfs 一起打包
```

### 三种典型用法

1. **SD 启动 + SPI 做存储**: 直接用 SD 镜像。板级 DTS 已含
   `flash@0 (jedec,spi-nor)` 节点, Linux 里表现为 `/dev/mtd0`,
   可用 busybox `flashcp`/`mtd_debug` 读写。
2. **SPI 放内核, SD 放根文件系统** (默认, U-Boot 已内置兜底启动):
   U-Boot bootcmd 顺序 = SD 卡 distro 启动 → 失败后 `sf read` 从 SPI
   加载内核 (root 仍为 `/dev/mmcblk0p2`)。更新 SPI 里的内核:
   把新 `zImage`/`sun8i-t113-s3.dtb` 拷进 SD 卡 boot 分区, U-Boot 命令行执行:

   ```
   mmc dev 0
   fatload mmc 0:1 ${scriptaddr} spi-update.scr
   source ${scriptaddr}
   ```

3. **全 NOR 启动** (`SPI_ROOTFS=1`): rootfs 为 squashfs 只读系统, 内核
   bootargs 需加分区表 (pack-spi 完成时会打印):
   `mtdparts=spi0.0:512k(uboot)ro,64k(dtb),10m(kernel),-(rootfs)
   root=/dev/mtdblock3 rootfstype=squashfs`。

### 其他烧写途径

- **Linux 运行中**: `flashcp t113-spi.img /dev/mtd0` (整片) 或按分区
  `dd if=zImage of=/dev/mtd2`
- **FEL (USB, 无卡救砖)**: `sunxi-fel spiflash-write 0 t113-spi.img`
  (需要 USB passthrough, Linux 宿主机或支持 USB 的虚拟机)

## 常用变量

```bash
make all MIRROR=cn            # 用 TUNA/Gitee 镜像拉源码 (默认 cn)
make image APT_MIRROR=mirrors.tuna.tsinghua.edu.cn   # apt 走国内源
KERNEL_VER=6.12.30 make fetch # 临时换内核版本 (tarball 版本号)
KERNEL_DTS=board make kernel  # 临时切换板级 DTS (auto/board/<名字>)
```

板级相关变量都在 `config/board.env` 里改。

## 烧写与部署

- **macOS**: `make flash DEV=/dev/disk4` (脚本会拒绝内置磁盘、先卸载再用 raw
  设备写入并自动弹出)
- **Linux**: `dd if=out/images/t113-sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress`

## 常见问题

- **`docker: command not found`**: `brew install docker docker-compose && colima start`
- **clone 慢/失败**: `make fetch MIRROR=cn` (内核走 TUNA tarball, 已实测 ~3MB/s),
  或手动把 `linux-x.y.z.tar.xz` 放到 `downloads/` 后重跑
- **权限问题** (容器里生成的文件属主异常): colima 虚拟机用户映射导致,
  `sudo chown -R $(id -u):$(id -g) out sources` 即可
- **串口没输出**: T113-S3 调试口是 UART3 (PB6/PB7), 确认接的是这两个引脚;
  若参考板 DTS 模式 (`KERNEL_DTS=auto`) 不匹配你的板子, 改用 board 模式
- **内核版本**: 改 `config/board.env` 的 `KERNEL_VER` (TUNA
  `kernel/v6.x/` 目录下的 6.6/6.12 LTS 均含 T113 DTS)
- **buildroot 打 ext4 报 xattr 错误**: 与 busybox rootfs 同理 (virtiofs 不支持
  xattr), 把 buildroot 输出目录放到容器本地: `make shell` 后
  `make -C sources/buildroot O=/tmp/br-output ...`, 或直接在 Linux 服务器上跑
- **colima 资源不足**: `colima stop && colima start --cpu 6 --memory 10 --disk 80`
