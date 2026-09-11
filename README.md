# T113-S3 Docker 编译环境

基于 Docker 的一站式 [Allwinner T113-S3](https://linux-sunxi.org/T113-s3) / [MangoPi MQ Dual](https://mangopi.org/mangopi_mq) 编译环境
(T113-i 同 die, 可直接复用): 主线 U-Boot + 主线 Linux (6.6 LTS) + busybox/Buildroot
根文件系统, 一条命令打出可启动的 SD 卡镜像与 SPI flash (NOR / NAND) 镜像, 并附带 macOS /
Linux / Windows(WSL2) 烧写脚本。

> 适配 Apple Silicon / Intel Mac (colima 或 Docker Desktop 均可), 同样适用于
> Linux 与 Windows(WSL2 + Docker Engine, 见 [docs/windows.md](docs/windows.md))。
> 需要编译全志**官方 SDK** (Longan/Tina, 仅支持 x86_64) 的见
> [docs/vendor-sdk.md](docs/vendor-sdk.md)。

## 环境要求

| 组件 | 说明 |
|------|------|
| Docker | macOS 推荐 [colima](https://github.com/abiosoft/colima) + `brew install docker docker-compose`; Windows 见 [docs/windows.md](docs/windows.md) (WSL2 + Docker Engine, 无需 Docker Desktop) |
| 磁盘 | ≥ 30 GB 空闲 (源码 ~2 GB + 编译产物 ~5 GB, 镜像另有余量) |
| 网络 | 拉取源码; 国内网络已内置 TUNA/Gitee 镜像 (`MIRROR=cn`) |

colima 用户建议给足资源 (宿主 8 核 16G 为例):

```bash
colima start --cpu 6 --memory 10 --disk 80
```

## 快速开始

```bash
make image          # 1. 构建 Docker 编译镜像 (首次, 约 5 分钟)
make all            # 2. 拉源码 + 编译 uboot/内核/busybox/apps/rootfs + 打包镜像
                    #    (内核编译约 15~40 分钟, 视机器而定)
make flash DEV=/dev/disk4   # 3. 插入 SD 卡, 烧写 (macOS 用 /dev/diskN;
                            #    Linux/WSL2 用 /dev/sdX, lsblk 查设备号)
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
make apps           # 编译 apps/ 用户应用 -> out/apps/ (rootfs 组装时自动执行)
make rootfs         # 组装根文件系统 -> out/rootfs.ext4
make pack           # 打包 SD 镜像 -> out/images/t113-sdcard.img
make pack-spi       # 打包 SPI flash 镜像 -> out/images/t113-spi.img (默认 SPI NAND)
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
│   └── board.env            # ★ 板级配置: 工具链/源码版本/defconfig/DTS/SPI 类型与布局
├── configs/
│   ├── kernel/t113_s3.config   # 内核增量配置 (合并到 defconfig)
│   ├── uboot/t113_s3.config    # U-Boot 增量配置 (SPI flash + 兜底启动 + 板级 DT)
│   └── buildroot/t113_s3_defconfig
├── board/
│   ├── boot.cmd             # U-Boot 启动脚本 (→ boot.scr)
│   ├── spi-update.cmd       # SD 卡 → SPI NOR 更新脚本 (→ spi-update.scr)
│   ├── spi-nand-update.cmd  # SD 卡 → SPI NAND 更新脚本 (→ spi-nand-update.scr)
│   ├── dts/sun8i-t113-s3.dts      # 内核板级 DTS 模板 (按硬件修改)
│   └── uboot-dts/sun8i-t113-s3.dts # U-Boot 板级 DTS (与内核 dtb 同名)
├── apps/                    # 用户应用 (每个子目录一个应用, 见 hello 示例)
├── patches/uboot/           # 对 U-Boot 源码的补丁 (sources/ 不入库, 编译前自动应用)
├── scripts/                 # 容器内编译脚本 + 宿主机烧写脚本
├── sources/                 # 拉取的源码 (make fetch 后出现, 不被 git 跟踪)
├── out/                     # 全部编译产物
│   ├── images/t113-sdcard.img   # SD 卡镜像
│   ├── images/t113-spi.img      # SPI flash 镜像 (NOR 或 NAND)
│   └── ...
├── docs/vendor-sdk.md       # 全志官方 SDK (Longan/Tina) 的 Docker 用法
├── docs/spi-nand.md         # SPI NAND (W25N02KVZEIR) 说明: 布局/烧写/启动链路
└── docs/windows.md          # Windows (WSL2 + Docker Engine) 安装 / 烧写指南
```

> `patches/uboot/0001-sunxi-spl-spi-nand.patch` 是让 **SPL 能从 SPI NAND 读 U-Boot**
> 的改动 (sunxi SPL SPI 驱动 + 启动源判断 + `SPL_SPINAND_SUPPORT` 配置项)。
> `make uboot` 每次会先把它应用到 `sources/uboot`, 已应用过则跳过;
> `make distclean` 之后再 `make fetch` 也不会丢。

## 用户应用 (apps)

`apps/` 下每个子目录一个应用, 用交叉工具链静态编译, 组装 rootfs 时自动装入
**/usr/bin** (板子串口里直接执行 `hello` 即可看到输出)。

```bash
make apps           # 只编译 apps/ (产物 out/apps/<name>/<name>)
make rootfs         # 组装 rootfs 前会自动先编译并装入 apps/
```

新增应用 = 新建 `apps/<name>/<name>.c` + `Makefile`, 直接复制 `apps/hello`
改名字即可, 约定:

- Makefile 用 `CROSS_COMPILE` (config/board.env 里已导出) 交叉编译;
- **必须静态链接** (`-static`): busybox 最小 rootfs 不带 glibc 动态库;
- 产物写到 `OUTPUT` 指向的 out/apps/ 下, 不要留在源码树。

> 用 `make rootfs-buildroot` (Buildroot) 时走 Buildroot 软件包机制,
> 不会自动装入 apps/ 下的应用。

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

T113-S3 的 SPI0 (PC2~PC5) 已打通, 支持两类介质, 由 `config/board.env` 的
`SPI_FLASH_TYPE` 选择:

| SPI_FLASH_TYPE | 介质 | 内核侧 | U-Boot 侧 |
|----------------|------|--------|-----------|
| `nand` (默认) | Winbond **W25N02KVZEIR** SPI NAND, 2Gbit / 256MB | MTD + SPI-NAND, `/dev/mtd*` | `mtd list/read/write/erase` |
| `nor` | 通用 SPI NOR, 16 或 32MB | MTD + SPI-NOR, `/dev/mtd*` | `sf probe/read/write/erase` |

> 内核 6.6 与 U-Boot 2025.01 的芯片表里都已内置 W25N02KV (ID `EF AA 22`),
> **不需要**像全志官方 SDK 那样改 `id.c`/`ecc.c` 打补丁。SPI NAND 详细说明
> (烧写、启动链路、限制) 见 [docs/spi-nand.md](docs/spi-nand.md)。

### 布局 (分区表由板级 DT 定义)

同一份分区表写在 `board/dts/${BOARD_DTS_NAME}.dts`(内核) 与
`board/uboot-dts/${BOARD_DTS_NAME}.dts`(U-Boot) 的 `partitions` 节点里,
内核与 U-Boot 共用; `make pack-spi` 打包前会校验它与 `config/board.env`
推导出的偏移一致, 不一致直接报错。分区顺序 = `mtd0..mtd3`, 所以根文件系统
固定是 `root=/dev/mtdblock3`。

**SPI NAND (默认, 256M)** —— 擦除块 128KB, 分区必须 128KB 对齐:

| 偏移 | 大小 | 分区名 | 内容 |
|------|------|--------|------|
| 0x0000000 | 1M | uboot | U-Boot (SPL + U-Boot proper) |
| 0x0100000 | 256K | dtb | `sun8i-t113-s3.dtb` |
| 0x0140000 | 16M | kernel | `zImage` (当前约 10.5M) |
| 0x1140000 | ~238M | rootfs | `rootfs.squashfs` (只读根文件系统) |

**SPI NOR (`SPI_FLASH_TYPE=nor`)** —— 16M/32M 用 `SPI_FLASH_SIZE_MB` 指定:

| 偏移 | 大小 | 内容 |
|------|------|------|
| 0x000000 | 512K | U-Boot (SPL + U-Boot, BootROM 从 0 地址引导) |
| 0x080000 | 64K  | 设备树 `sun8i-t113-s3.dtb` |
| 0x100000 | 12M  | `zImage` (10M 分区放不下当前内核) |
| 0xD00000 | 剩余 | `rootfs.squashfs` (只读根文件系统) |

- **32M NOR**: rootfs 区 ~19M; 最小 busybox 系统 squashfs 后约 1.3M, 装系统
  + 应用绰绰有余 (推荐)
- **16M NOR**: rootfs 区仅 ~3M, 只够最小系统, 应用多了建议换 32M

```bash
# 默认就是 SPI NAND 256M 全 flash 镜像
make pack-spi
# 换 NOR 板: 三处要一起改 (只改这里会被 pack-spi 的一致性校验拦住)
#   1) config/board.env            : SPI_FLASH_TYPE=nor
#   2) board/dts, board/uboot-dts  : flash 节点换成注释里的 jedec,spi-nor
#   3) configs/uboot/t113_s3.config: 换成注释里那行 sf read 版 CONFIG_BOOTCOMMAND
SPI_FLASH_TYPE=nor SPI_FLASH_SIZE_MB=32 make pack-spi
```

`SPI_ROOTFS` 默认已是 1 (squashfs rootfs 也打进 flash, 构成"全 flash 系统")。

### 默认架构: 全 flash 系统 + SD 卡用户数据

U-Boot 启动顺序 = SPI flash 系统优先, 失败才回落到 SD 卡 distro 启动:

1. **SPI flash (只读系统)**: 内核 + squashfs 只读系统/程序 (`apps/` 的应用
   自动装入 /usr/bin, 见上文「用户应用 (apps)」)。
2. **SD 卡 (用户数据)**: 从 flash 启动后 rcS 自动把 SD 卡 **p1** 挂到 `/data`
   (ext4/vfat 均可, 无卡或没有 p1 分区则跳过)。首次准备数据卡:

   ```bash
   # Linux 宿主机: SD 卡分一个区并格式化 (ext4 或 vfat 任选)
   sudo mkfs.ext4 -L userdata /dev/sdX1
   # 或: sudo mkfs.vfat -n userdata /dev/sdX1
   ```

   开机后 `mount | grep /data` 确认, 用户文件放 `/data` 即落在 SD 卡上。
3. **开发 / 恢复**: `make pack` 的 t113-sdcard.img 不变, 在 flash 未烧写或
   系统损坏时插上即可从 SD 启动 (boot.scr 自己指定 root=/dev/mmcblk0p2,
   不会动 /data)。更新 flash 里的内核: 把 zImage/dtb 拷进开发 SD 卡 boot
   分区, U-Boot 命令行执行 `source spi-nand-update.scr` (SPI NAND, 脚本见
   board/spi-nand-update.cmd) 或 `source spi-update.scr` (SPI NOR)。

> **SPL 自己会从 SPI flash 读 U-Boot**, 所以插不插 SD 卡都能启动: 从 SD 启动时
> SPL 从卡上读 U-Boot, 从 flash 启动时 SPL 先读芯片 ID 自动区分 NAND / NOR
> 再读 U-Boot (实现见 `sources/uboot/arch/arm/mach-sunxi/spl_spi_sunxi.c`,
> 由 `CONFIG_SPL_SPI_SUNXI` + `CONFIG_SPL_SPINAND_SUPPORT` 打开)。
> 前提是 flash 的 `uboot` 分区已烧好、且该区域没有坏块 —— 细节和限制见
> [docs/spi-nand.md](docs/spi-nand.md#5-启动链路)。

### 其他烧写途径

- **U-Boot 命令行**: 插着 SD 卡时 `fatload mmc 0:1 ${scriptaddr} spi-nand-update.scr`
  再 `source ${scriptaddr}` (NAND) / `spi-update.scr` (NOR)
- **Linux 运行中**: 按分区写单个文件 (NAND 必须经 MTD 层, 不能 dd):
  `flashcp zImage /dev/mtd2`
- **FEL (USB, 无卡救砖)**: NAND 用 `xfel spi_nand write 0 t113-spi.img`,
  NOR 用 `sunxi-fel spiflash-write 0 t113-spi.img`
  (需要 USB passthrough, Linux 宿主机或支持 USB 的虚拟机)

## 常用变量

```bash
make all MIRROR=cn            # 用 TUNA/Gitee 镜像拉源码 (默认 cn)
make image APT_MIRROR=mirrors.tuna.tsinghua.edu.cn   # apt 走国内源
PROXY=http://192.168.5.2:7890 make fetch            # 下载走宿主机代理 (colima)
make image PROXY=http://192.168.5.2:7890            # 构建镜像时也走代理
# Docker Desktop 用 http://host.docker.internal:7890; Linux 容器用 http://127.0.0.1:7890
KERNEL_VER=6.12.30 make fetch # 临时换内核版本 (tarball 版本号)
KERNEL_DTS=board make kernel  # 临时切换板级 DTS (auto/board/<名字>)
SPI_FLASH_TYPE=nand make pack-spi   # 临时切 flash 类型 (nand 默认 / nor)
```

板级相关变量都在 `config/board.env` 里改。

## 烧写与部署

- **macOS**: `make flash DEV=/dev/disk4` (脚本会拒绝内置磁盘、先卸载再用 raw
  设备写入并自动弹出)
- **Linux / WSL2**: `make flash DEV=/dev/sdX` (需要时自动 `sudo`, 带防呆检查;
  手动等价命令: `dd if=out/images/t113-sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress`)
- **Windows**: 在 WSL2 里按上一条执行 (SD 读卡器需先用 usbipd 透传), 或直接在
  Windows 侧用 Rufus 等图形工具烧 `out\images\t113-sdcard.img`;
  完整步骤见 [docs/windows.md](docs/windows.md)

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
