# Windows (WSL2 原生 Ubuntu) 使用指南

本项目的编译需要 Linux 工具链 (armhf 交叉编译器 + dtc/mkimage/mtools/mtd-utils)。
Windows 下的做法是在 **WSL2 的 Ubuntu 里原生构建** —— 不需要 Docker: 依赖用
`make deps` 装一次, 之后 `make` 系列命令和在 Linux 上完全一样。

```
Windows 11/10
  └─ WSL2 (Ubuntu 22.04+, 推荐 24.04)      ← 在这里跑 make
       └─ 项目源码 (强烈建议放 WSL 原生盘 ~/)  ← 源码与编译产物都在这里
```

> **为什么不用 Docker**: 容器只是把同一套 apt 包装进镜像, 对 Windows 没有额外好处 ——
> 容器的 bind mount 依然落在 Windows 盘上, 既没有性能优势, 也解决不了第 3 节的大小写
> 问题; 反而多一层 daemon 要维护。容器路径只保留给 macOS (macOS 没有 Linux 工具链)。
> 需要时可用 `ENGINE=docker` 强制走容器, 但 Windows 下的官方路径就是原生。

---

## 1. 启用 WSL2 并安装 Ubuntu

在 **管理员 PowerShell** 中:

```powershell
wsl --install -d Ubuntu
```

按提示重启。重启后确认发行版是 WSL **2**:

```powershell
wsl -l -v
# 若 VERSION 显示 1:  wsl --set-version Ubuntu 2
```

进入 Ubuntu:

```bash
sudo apt update && sudo apt -y upgrade
```

> 本项目**不需要 systemd** (不装服务、不跑 daemon)。如果你因为别的原因已经开了
> `/etc/wsl.conf` 的 `systemd=true`, 也不影响构建。

## 2. 安装编译依赖

编译依赖 (arm 交叉工具链、dtc/mkimage、mtools/mtd-utils、qemu-user-static 等)
在 `docker/packages.txt` 里, 一条命令装完:

```bash
cd <项目目录>
make deps            # = apt-get install 清单里的全部包 (需要 sudo 密码)
make check           # 校验工具链是否齐全
make info            # 查看 gcc / dtc / mkimage 版本
```

`make deps` 本身要用 make, WSL 的 Ubuntu 默认自带; 若提示 `make: command not found`,
先 `sudo apt install -y make`, 或等效地手动装:

```bash
sudo apt-get update
sudo apt-get install -y $(grep -vE '^[[:space:]]*(#|$)' docker/packages.txt | tr '\n' ' ')
```

apt 慢的话可先配清华源。

## 3. 项目放哪里: 强烈建议放 WSL 原生盘 (ext4)

**两个理由**:

1. **大小写敏感性**。WSL 挂载的 Windows 盘 (`/mnt/d`) 是 NTFS, 大小写不敏感, 而
   源码树里存在仅大小写不同的文件名 —— 内核 `include/uapi/linux/netfilter/` 下就有
   `xt_CONNMARK.h` 与 `xt_connmark.h`、`xt_MARK.h` 与 `xt_mark.h` 等。在 `/mnt/d` 上
   解压/检出时它们会落成同一个文件, **静默少掉一个**, 之后表现为"莫名缺少头文件"。
   `make fetch` 会检测这种情况并直接报错 (git clone 自己也会警告 `paths have collided`)。
2. **性能**。内核这种几万个小文件的编译, 走 9p 挂载的 Windows 盘比 ext4 慢好几倍。

```bash
cd ~ && git clone <你的仓库地址> t113s3-sdk && cd t113s3-sdk
```

Windows 侧访问这份代码, 两种方式都很好用:

- **VSCode Remote-WSL**: 装 "WSL" 扩展, 在 WSL 里进项目目录执行 `code .`
- **资源管理器**: 地址栏输入 `\\wsl$\Ubuntu-22.04\home\<用户名>\t113s3-sdk`

如果你把项目留在 `/mnt/d` (例如 `D:\Projects\t113s3-sdk`), 构建前需要接受上面的
风险: `ALLOW_CASE_INSENSITIVE=1 make fetch` 可以跳过检测, 但编译可能因缺文件失败,
而且速度慢。**放到 `~` 下是唯一推荐的做法。**

**换行符**: 仓库已带 `.gitattributes` 强制脚本保持 LF, 在 WSL 里克隆/使用无需任何
处理。只有一种情况需要手动修复 —— 仓库是被 **Windows Git 在加入 `.gitattributes`
之前**克隆的 (`core.autocrlf=true` 会把 `.sh` 检出成 CRLF, 报
`$'\r': command not found`):

```bash
cd <仓库目录>
git config core.autocrlf false
git add --renormalize . && git status    # 确认改动后提交一次即可
```

## 4. 构建

```bash
make deps      # 首次装依赖 (第 2 节)
make all       # 拉源码 + uboot/kernel/rootfs + 打包 SD/SPI 镜像
make shell     # 需要手动 menuconfig / 单步调试时进 shell (工具链变量已载入)
```

也可以分步: `make fetch` / `make uboot` / `make kernel` / `make busybox` /
`make apps` / `make rootfs` / `make pack` / `make pack-spi`。

**拉源码慢/失败 (走代理)**: U-Boot/buildroot 源码是 git clone, 源用 GitHub 官方镜像,
国内一般要挂代理, 否则会很慢甚至卡住。

```bash
make proxy-hint                      # 打印宿主代理地址 (WSL 里别用 127.0.0.1)
PROXY=http://172.29.160.1:7890 make fetch   # 地址以 proxy-hint 输出为准
MIRROR=official make fetch           # 换官方源 (denx.de / gitlab.com)
```

- **WSL2 默认是 NAT 网络**: 代理跑在 Windows 上时, WSL 里的 `127.0.0.1` 指向 WSL
  自己, 够不到 Windows 的代理, 要用**宿主网关地址** (`make proxy-hint` 会算出来,
  一般是 `172.x.x.1`)。
- 想让 `127.0.0.1` 直接可用, 可以在 `%UserProfile%\.wslconfig` 里加
  `networkingMode=mirrored` (WSL 2.0+), `wsl --shutdown` 后 WSL 与 Windows 共享
  localhost, 那时 `PROXY=http://127.0.0.1:7890` 就能用。
- 某个镜像停滞 (3 分钟无数据) 会自动换下一个, 阈值可调:
  `GIT_STALL_PROBES=4 GIT_STALL_INTERVAL=20 make fetch`。

**内存与并行度**: WSL 默认只分给虚拟机一半内存, 而 `JOBS` 默认取 `nproc`
(宿主机全部逻辑核), 全核并行编内核有 OOM 风险 —— 内存不足时用 `JOBS` 限制:

```bash
JOBS=8 make all              # 限制并行任务数 (临时)
```

想给 WSL 更多资源, 在 `%UserProfile%\.wslconfig` 里配置后执行 `wsl --shutdown` 生效:

```ini
[wsl2]
memory=24GB
processors=16
swap=8GB
```

> 宿主 32 核 / 32G 的话, 别照搬网上的 `memory=10GB` + `processors=6`: 核多内存少
> 反而更容易 OOM。要么给足内存 (比如 24GB), 要么用 `JOBS=` 把并行度压下来。

## 5. 烧写 SD 卡 (usbipd USB 透传)

### 5.1 装 usbipd 并透传读卡器

在 **管理员 PowerShell** 中:

```powershell
winget install usbipd
```

插上 SD 读卡器后:

```powershell
usbipd list                        # 找到读卡器对应的 BUSID (Type 为 USB 的项)
usbipd bind --busid <BUSID>        # 首次使用该 USB 口时需要 bind 一次
usbipd attach --wsl --busid <BUSID>
```

attach 后设备会出现在 WSL 里, 回到 WSL 终端确认设备名:

```bash
lsblk        # 读卡器一般是 /dev/sda (有 sda1 等小分区属正常)
```

### 5.2 烧写

```bash
cd <项目目录>
make flash DEV=/dev/sda            # 设备名以 lsblk 为准
```

`make flash` 在 WSL (Linux) 里会走 `scripts/flash-linux.sh`, 需要时自动 `sudo`,
并带防呆检查: 拒绝分区设备、拒绝非可移动磁盘、拒绝已挂载设备、校验镜像 ≤ 卡容量。
确实要强制时用 `FORCE=1 make flash DEV=/dev/sda`。

### 5.3 烧完回收设备

```powershell
usbipd detach --busid <BUSID>      # Windows 管理员 PowerShell
```

> **不用透传的替代方案**: 直接在 Windows 侧用图形工具烧, 效果等同 dd ——
> 下载/使用 Rufus 或 balenaEtcher / Win32DiskImager, 选择镜像
> `out\images\t113-sdcard.img` 写入 SD 卡。项目在 WSL 原生盘时, 该文件路径为
> `\\wsl$\Ubuntu-22.04\home\<用户名>\t113s3-sdk\out\images\t113-sdcard.img`。
>
> FEL (USB 免卡救砖/烧 SPI) 同样在 WSL2 里做: `usbipd attach` 透传后
> `sudo apt install sunxi-tools && sunxi-fel spiflash-write 0 t113-spi.img`。

## 6. 常见问题

| 现象 | 处理 |
|------|------|
| `make: command not found` | WSL 里 `sudo apt install -y make` |
| `缺少编译工具: dtc mkimage arm-linux-gnueabihf-gcc ...` | `make deps` (包清单 `docker/packages.txt`) |
| `make fetch` 报"文件系统大小写不敏感...覆盖丢失" 或 git clone 警告 `paths have collided` | 项目在 `/mnt/d` 上, 按第 3 节移到 WSL 原生盘 (`cd ~ && git clone ...`); 确要强行继续用 `ALLOW_CASE_INSENSITIVE=1 make fetch` |
| 内核编译 OOM / 太慢 | `JOBS=8 make all` 限并行 + 调 `%UserProfile%\.wslconfig`; 源码放 WSL 原生盘 |
| `make help` 提示 "当前是 Windows 原生 shell" | 在 Git Bash/PowerShell 里跑了 make。构建只能在 WSL 终端里做 |
| 脚本报 `$'\r': command not found` | 仓库被 Windows Git (autocrlf) 检出过, 按第 3 节 renormalize |
| WSL 显示 VERSION 1 | `wsl --set-version Ubuntu 2` (需管理员 PowerShell, 重启 WSL) |
| usbipd attach 报错 | 用管理员 PowerShell; 先 `usbipd bind`; `wsl --update` 后重试 |
| `/mnt/d` 下 `out/` 属主/权限怪异 | 只有混用过容器才会出现 (容器以 root 写入): `sudo chown -R $(id -u):$(id -g) out sources downloads`; 原生构建不会有这个问题 |
| 拉源码慢/失败/卡住 | 挂代理: `make proxy-hint` 看地址后 `PROXY=http://<宿主网关>:7890 make fetch` (WSL 里 `127.0.0.1` 到不了 Windows 的代理); 或 `MIRROR=official make fetch` 换源 |

> 需要编译全志官方 SDK (Longan/Tina, 仅支持 x86_64) 时, WSL2 的 amd64 Ubuntu
> 天然满足硬件要求 —— 同样**在 WSL2 里原生执行**即可, 具体步骤见
> [docs/vendor-sdk.md](vendor-sdk.md)。
