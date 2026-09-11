# SPI NAND (Winbond W25N02KVZEIR) 说明

本项目默认的 SPI flash 是 **Winbond W25N02KVZEIR** (2Gbit / 256MB SPI NAND),
内核 (Linux 6.6) 与 U-Boot (v2025.01) 都已内置该芯片的支持, 也都能直接跑在
T113-S3 的 SPI0 上 (PC2~PC5)。

## 1. 芯片与"要不要打补丁"

| 项目 | 值 |
|------|-----|
| 容量 | 2Gbit = 256MB |
| JEDEC ID | `EF AA 22` |
| 页大小 | 2048B + 128B OOB |
| 擦除块 | 128KB (64 页) |
| 块数 | 2048 |
| 最大坏块 | 40 块/片 (出厂保证) |
| 片内 ECC | 8bit/512B (由芯片自己算, 驱动只读状态) |

主线代码里的芯片表位置:

- 内核 `drivers/mtd/nand/spi/winbond.c` → `W25N02KV` (`NAND_MEMORG(1, 2048, 128, 64, 2048, ...)`)
- U-Boot `drivers/mtd/nand/spi/winbond.c` → `W25N02KV`

> 全志官方 SDK (Tina/Longan) 用的是自己那套 `sunxi-spinand-phy` 驱动, 所以要手工往
> `id.c` 里加 `W25N02KVZEIR` 表项, 内核侧还要动 `ecc.c`/`physic.h`
> (参考 [whycan 上的适配帖](https://whycan.com/t_10272.html) 与
> [AWOL 的存储介质切换帖](https://bbs.aw-ol.com/topic/1701/))。
> **本项目走主线驱动, 不需要这些补丁。**

## 2. 构建

```bash
# 关键: 内核必须用板级 DTS (上游参考板 DTS 里没有 spi0/flash 节点)
KERNEL_DTS=board make kernel        # 或把 board.env 的 KERNEL_DTS 默认值改成 board
make uboot                          # UBOOT_DTS 默认已是 board
make rootfs
make pack-spi                       # 产出 out/images/t113-spi.img (256M)
make pack                           # SD 卡镜像 (含 boot.scr / spi-nand-update.scr)
```

容器里跑的话前面加 `make shell` 或直接用 `make <目标>`。

> `make uboot` 会先把 `patches/uboot/0001-sunxi-spl-spi-nand.patch` 应用到
> `sources/uboot` (已应用则跳过)。这个补丁给 SPL 加了 SPI NAND 读取支持
> (见第 5 节), 因为 `sources/` 不被 git 跟踪、`make fetch` 会重新克隆,
> 所以改动以补丁形式保留 —— 改完 U-Boot 源码记得重新生成补丁:
> `cd sources/uboot && git diff > ../../patches/uboot/0001-sunxi-spl-spi-nand.patch`

切回 SPI NOR:

1. `config/board.env`: `SPI_FLASH_TYPE=nor` (`SPI_FLASH_SIZE_MB` 默认变 16)
2. `board/dts/` 与 `board/uboot-dts/` 里: 用 `jedec,spi-nor` 节点替换 `spi-nand` 节点
   (两个文件里都留了注释好的版本)
3. `configs/uboot/t113_s3.config`: 换成注释里那行 `sf read` 版的 `CONFIG_BOOTCOMMAND`

## 3. 分区布局

SPI NAND 的最小擦除单位是 128KB, 所以**所有分区偏移/大小都必须是 128KB 的整数倍**,
否则内核和 U-Boot 会拒绝该分区 (`doesn't start on an erase block boundary`)。

| 偏移 | 大小 | 分区名 | 内容 | mtd |
|------|------|--------|------|-----|
| 0x0000000 | 1M | uboot | U-Boot (SPL + U-Boot proper) | mtd0 |
| 0x0100000 | 256K | dtb | `sun8i-t113-s3.dtb` | mtd1 |
| 0x0140000 | 16M | kernel | `zImage` | mtd2 |
| 0x1140000 | ~238M | rootfs | `rootfs.squashfs` | mtd3 |

布局有三个"作者":

- `config/board.env` 的 `SPI_UBOOT_SIZE` / `SPI_DTB_SIZE` / `SPI_KERNEL_SIZE`
  → 由 `scripts/env.sh` 的 `spi_layout()` 推出偏移, 供 `pack-spi.sh` 拼镜像;
- `board/dts/${BOARD_DTS_NAME}.dts` 与 `board/uboot-dts/${BOARD_DTS_NAME}.dts`
  的 `partitions` 节点 → 内核 (ofpart) 与 U-Boot (`mtd` 命令) 按名字识别分区;
- `configs/uboot/t113_s3.config` 的 `CONFIG_BOOTCOMMAND` → 只用分区名, 不写死偏移。

`make kernel` / `make uboot` / `make pack-spi` 都会调用 `check_dts_partitions()`
逐项比对 DTS 与 `board.env`, 不一致时直接报错 (避免镜像被写到错误偏移)。

内核 cmdline 不再需要 `mtdparts`, 分区全部来自 DTB; 因为分区顺序是
uboot/dtb/kernel/rootfs, 根设备固定为 `root=/dev/mtdblock3`、`rootfstype=squashfs`。

## 4. 烧写

**SPI NAND 不能 `dd`/`flashcp` 整片线性镜像** —— NAND 的写入必须经 MTD 层,
由驱动生成 OOB 与 ECC、跳过坏块。三种可行方式:

### 4.1 U-Boot 下从 SD 卡刷新 (推荐)

把 `out/images/t113-sdcard.img` 烧到 SD 卡 (boot 分区里已经有
`zImage`/`dtb`/`u-boot-sunxi-with-spl.bin`/`spi-nand-update.scr`),
上电停在 U-Boot, 然后:

```
mmc dev 0
fatload mmc 0:1 ${scriptaddr} spi-nand-update.scr
source ${scriptaddr}
```

脚本 (`board/spi-nand-update.cmd`) 做的是 `mtd erase <分区>` + `mtd write
<分区> <内存> 0 ${filesize}` —— 用分区名而不是偏移。它默认只更 dtb 和 kernel;
**空片第一次烧写**或换 U-Boot 时, 还要把脚本里"更新 uboot 分区"那段取消注释
(那是能让 flash 独立启动的部分), rootfs 同理 (注释里给了现成的几行)。

### 4.2 系统里 (Linux) 按分区写

```sh
cat /proc/mtd                      # mtd0=uboot mtd1=dtb mtd2=kernel mtd3=rootfs
flashcp zImage   /dev/mtd2         # 先传到板子上 (SD 卡 / scp / tftp)
flashcp sun8i-t113-s3.dtb /dev/mtd1
```

`flashcp` 是 busybox 自带 applet (需内核为 busybox 打开该 applet)。
没有 `flashcp` 时用 `flash_erase /dev/mtd2 0 0` + `nandwrite -p /dev/mtd2 zImage`。

### 4.3 FEL (无卡救砖)

```bash
xfel spi_nand write 0 out/images/t113-spi.img     # 整片 256M, 较慢
```

`xfel` 是宿主机上的 FEL 工具 (非本项目依赖), 需要 USB 通路。
注意 FEL 写的是**线性内容**, xfel 会自己处理 NAND 的页/OOB 布局。

## 5. 启动链路

```
BootROM ──> SPL (u-boot-spl) ──> U-Boot proper ──> zImage (kernel 分区)
   │              │                    └─ rootfs.squashfs (rootfs 分区, 只读)
   │              └─ SPL 自己也从 SPI flash 读 U-Boot
   └─ 找不到 SD 就从 SPI flash 读 SPL
```

1. **BootROM**: 按 SD → SPI (NOR/NAND) → eMMC 的顺序找 `eGON.BT0` 引导头,
   flash 上的镜像从偏移 0 开始写 (SPI NAND 上的 boot0 同样在块 0)。
2. **SPL 加载 U-Boot**: SPL 里编进了自己的 SPI 读 flash 实现
   (`arch/arm/mach-sunxi/spl_spi_sunxi.c`, 由 `CONFIG_SPL_SPI_SUNXI` +
   `CONFIG_SPL_SPINAND_SUPPORT` 打开), 所以 **插不插 SD 卡都能启动**:

   - 从 SD 启动时 SPL 从 SD 读 U-Boot (原逻辑不变);
   - 从 SPI flash 启动时, SPL 先读芯片 ID 判断挂的是 NAND 还是 NOR
     (Winbond NAND = `EF AA xx`, NOR = `EF 40 xx`), 再用对应的读法把
     U-Boot 读出来。镜像布局是 `[SPL][uImage 头 64B][u-boot.bin]`,
     U-Boot 的偏移取自 SPL 头里的长度和 `CONFIG_SYS_SPI_U_BOOT_OFFS`。

   本项目的 SPL 实现参考了上游 RFC 系列
   [Support SPI NAND booting on the T113](https://patchwork.ozlabs.org/project/uboot/cover/20240411-spinand-v1-0-62d31bb188e8@jookia.org/),
   但没有采用它的 `BOOT_DEVICE_SPINAND` / UBI 启动部分: 改成读 ID 判断芯片类型,
   这样 BROM 上报 3 (SPI) 还是 4 (SPI NAND) 都能启动, NOR 板也共用同一份 SPL。
3. **U-Boot 加载内核**: bootcmd 用 `mtd read dtb` + `mtd read kernel` + `bootz`
   (按分区名, 不写死偏移), 失败才 `run distro_bootcmd` 回落到 SD 卡启动。
   U-Boot 里的命令是 `mtd list / mtd read / mtd write / mtd erase` ——
   **`sf` 命令只认 SPI NOR**, 在 NAND 板上会 `probe failed`。

## 6. 已知限制

1. **U-Boot 环境变量**: NAND 板上没有 NOR, `CONFIG_ENV_IS_IN_SPI_FLASH` 会回退到
   编译进去的默认环境 —— 启动没问题, 但 `saveenv` 不可用。要持久化 env 需要
   UBI (`CONFIG_ENV_IS_IN_UBI`) 或把 env 放到 SD 卡上, 目前都没接。
2. **坏块**: SPL 从 flash 读 U-Boot 是**线性**读 (页地址 = 字节偏移 / 2048),
   不跳过坏块; 内核 rootfs 走 `mtdblock` + squashfs 同理。而 U-Boot 的
   `mtd write` 是**会跳过坏块**写的, 两者只在"uboot/kernel 分区里没有坏块"时一致。
   出厂新片 (W25N02KV 最多 40 个坏块/片) 在这几个分区里基本不会有坏块; 如果
   启动报 `SPI NAND` 读失败或内核 CRC 错, 先 `mtd list` + `mtd read` 确认,
   必要时换一块好的区域/芯片。彻底解决要上 UBI (`ubiformat` + `ubiblock`)。
3. **写寿命**: rootfs 是只读 squashfs, 系统盘几乎没有磨损; 频繁写的数据请放
   SD 卡的 `/data`。
4. 内核 cmdline 里不需要 `mtdparts`; 如果你手动传了 `mtdparts`, U-Boot 与内核
   都会优先用它, 反而会盖掉 DTB 里的分区 —— 别传。

## 7. 排错

```sh
# SPL 阶段 (串口最早的那几行)
#   正常: 从 SD 启动时看不到 SPI 相关输出; 从 flash 启动时会读 ID 选路径
#   失败: "SPL: failed to boot from all boot devices" -> flash 里 uboot 分区不对
#         (没烧写 / 偏移不对 / 有坏块), 插 SD 卡仍可从卡启动

# U-Boot 里
mtd list                      # 应看到 spi-nand0 及其 4 个分区 (uboot/dtb/kernel/rootfs)
mtd read dtb ${fdt_addr_r}    # 单独验证读取
mtd read uboot ${loadaddr}    # 验证 uboot 分区可读 (看到 uImage 头/裸镜像)
sf probe                      # NAND 板上必然失败, 这是正常的 (sf 只认 NOR)

# 内核起来后
dmesg | grep -i -E "spinand|spi-nand|nand"
# 正常会看到: spi-nand0: ... W25N02KV ...
cat /proc/mtd                 # mtd0..mtd3 按上面的表
mount | grep " / "            # 应该是 rootfs.squashfs on /dev/mtdblock3 ...
```

常见现象:

- `mtd read: MTD device 'dtb' not found` → 板级 DT 没生效 (内核/UBoot 用的是
  上游参考板 DTS), 检查 `KERNEL_DTS=board` / `UBOOT_DTS=board`;
- 分区被强制只读 / `mtd: partition "..." doesn't start on an erase block boundary`
  → 分区偏移或大小没按 128KB 对齐 (见第 3 节, 改完 `board.env` 记得同步 DTS);
- `SPL: failed to boot from all boot devices` → flash 里的 uboot 分区没烧好
  (见第 5/6 节); 插上 SD 卡可以从卡启动, 再用 `spi-nand-update.scr` 重刷;
- 识别不到芯片 → 确认是 SPI0 (PC2~PC5) 且 `spi-max-frequency` 没超过 40MHz,
  另外 3.3V 供电正常; `mtd list` 里应能看到 `W25N02KV`。
