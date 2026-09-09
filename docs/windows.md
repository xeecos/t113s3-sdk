# Windows (WSL2 + Docker Engine) 使用指南

本项目的编译全部发生在 Docker **Linux 容器**内 (`docker compose run --rm
t113-build`), 与宿主系统无关。因此在 Windows 上不需要 Docker Desktop, 推荐做法是:

```
Windows 11/10
   └─ WSL2 (Ubuntu, 推荐 22.04/24.04)          ← 运行 make / docker
        └─ Docker Engine (装在 WSL 内)          ← 编译容器在此执行
             └─ 项目源码 (放 /mnt/d 或 WSL 原生盘均可)
```

装好之后的使用体验与 Linux 完全一致: 在 WSL 终端里进项目目录执行
`make image` / `make all` / `make flash` 即可。烧写 SD 卡时, 用开源工具
`usbipd-win` 把读卡器透传给 WSL。

> 如果你更想用 Docker Desktop (图形界面), 仓库也完全兼容 —— 只需把下面的
> Docker 安装步骤换成 [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/),
> 并在 Docker Desktop 的 Settings → Resources → WSL Integration 里打开你的发行版,
> 其余步骤不变。

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

进入 Ubuntu (默认用户为 `wsl --set-default Ubuntu` 后可只用 `wsl`):

```bash
sudo apt update && sudo apt -y upgrade
```

**systemd**: WSL 需要 systemd 才能把 Docker 当作服务管理。较新的 WSL 默认已开启,
可先验证, 未开启则手动打开:

```bash
systemctl is-system-running --no-pager    # 能返回 running/degraded 即已开启

# 若报 "System has not been booted with systemd":
sudo sh -c 'printf "[boot]\nsystemd=true\n" > /etc/wsl.conf'
# 然后在 Windows 执行:  wsl --shutdown   再重新进入
```

## 2. 在 WSL 里安装 Docker Engine

官方一键脚本 (在 WSL 终端内):

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"        # 之后免 sudo 用 docker (重新登录 wsl 生效)
sudo systemctl enable --now docker
docker run --rm hello-world             # 验证
docker compose version                  # 需 compose v2 插件 (官方脚本自带)
sudo apt install -y make                # Makefile 入口 (Ubuntu 默认不带)
```

> 没有 systemd 的老环境: 用 `sudo service docker start` 代替
> `systemctl enable --now docker`。
> apt 慢的话可先配清华源, 项目内已支持 `MIRROR=cn` / `APT_MIRROR=...` 走国内镜像。

## 3. 放置项目 (两种方式)

仓库已在 Windows 盘时 (如 `D:\Projects\t113s3-sdk`), WSL 里对应
`/mnt/d/Projects/t113s3-sdk`, 直接进去跑即可:

```bash
cd /mnt/d/Projects/t113s3-sdk
make image && make all
```

- **优点**: Windows 侧 (资源管理器 / VSCode / 你现有的 Git) 直接访问, 无需迁移。
- **缺点**: 代码在 NTFS (`/mnt/d`) 上, 内核这种大量小文件的编译会比 WSL 原生盘
  慢一些。

追求性能的话, 克隆到 WSL 原生盘 (ext4) 编译, 用 `\\wsl$\Ubuntu\...` 或
VSCode Remote-WSL 从 Windows 侧访问:

```bash
cd ~ && git clone https://你的仓库地址 t113s3-sdk && cd t113s3-sdk
```

**换行符**: 仓库已带 `.gitattributes` 强制脚本保持 LF, 在 WSL 里克隆/使用无需任何
处理。只有一种情况需要手动修复 —— 仓库是被 **Windows Git 在加入
`.gitattributes` 之前**克隆的 (`core.autocrlf=true` 会把 `.sh` 检出成 CRLF,
进容器会报 `$'\r': command not found` 之类的错):

```bash
cd <仓库目录>
git config core.autocrlf false
git add --renormalize . && git status    # 确认改动后提交一次即可
```

## 4. 构建

进 WSL 终端, 与 README 一致:

```bash
make image    # 构建编译镜像 (首次约 5 分钟)
make all      # 拉源码 + uboot/kernel/rootfs + 打包 SD/SPI 镜像
make shell    # 进入容器调试
```

建议给 WSL 足够资源。在 `%UserProfile%\.wslconfig` 里配置后执行
`wsl --shutdown` 生效:

```ini
[wsl2]
memory=10GB
processors=6
swap=8GB
```

/mnt/d 权限异常 (容器以 root 生成的 out/ 属主怪异) 时:

```bash
sudo chown -R $(id -u):$(id -g) out sources downloads
```

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

`make flash` 会自动按宿主系统选择脚本 —— WSL (Linux) 走
`scripts/flash-linux.sh`, 它会在需要时自动 `sudo`, 并带防呆检查:
拒绝分区设备、拒绝非可移动磁盘、拒绝已挂载设备、校验镜像 ≤ 卡容量。
确实要强制时用 `FORCE=1 make flash DEV=/dev/sda`。

### 5.3 烧完回收设备

```powershell
usbipd detach --busid <BUSID>      # Windows 管理员 PowerShell
```

> **不用透传的替代方案**: 直接在 Windows 侧用图形工具烧, 效果等同 dd ——
> 下载/使用 Rufus 或 balenaEtcher / Win32DiskImager, 选择镜像
> `out\images\t113-sdcard.img` 写入 SD 卡。仓库在 WSL 原生盘时, 该文件路径为
> `\\wsl$\Ubuntu\home\<用户名>\t113s3-sdk\out\images\t113-sdcard.img`。
>
> FEL (USB 免卡救砖/烧 SPI) 同样在 WSL2 里做: `usbipd attach` 透传后
> `sudo apt install sunxi-tools && sunxi-fel spiflash-write 0 t113-spi.img`。

## 6. 常见问题

| 现象 | 处理 |
|------|------|
| `make: command not found` | WSL 里 `sudo apt install -y make` |
| `permission denied ... docker.sock` | `sudo usermod -aG docker $USER` 后重开 wsl 终端 (或 `newgrp docker`) |
| `Cannot connect to the Docker daemon` | 检查 systemd: `systemctl status docker`; 未开 systemd 用 `sudo service docker start`, 并见第 1 节 wsl.conf 配置 |
| 脚本报 `$'\r': command not found` | 仓库被 Windows Git (autocrlf) 检出过, 按第 3 节 renormalize |
| `container name "t113-build" already in use` | `docker rm -f t113-build` (正常情况下 `run --rm` 会自动清理) |
| WSL 显示 VERSION 1 | `wsl --set-version Ubuntu 2` (需管理员 PowerShell, 重启 WSL) |
| 内核编译 OOM / 太慢 | 调 `%UserProfile%\.wslconfig` 资源并 `wsl --shutdown`; 源码放 WSL 原生盘 |
| usbipd attach 报错 | 用管理员 PowerShell; 先 `usbipd bind`; `wsl --update` 后重试 |
| /mnt/d 下文件属主/权限怪异 | 见第 4 节 chown; 或干脆把项目迁到 WSL 原生盘 |
| 拉源码慢/失败 | `make all MIRROR=cn`, 见 README 常见问题 |

> 需要编译全志官方 SDK (Longan/Tina, 仅支持 x86_64) 时, WSL2 的 amd64 Ubuntu
> 天然满足硬件要求 —— 在 WSL2 里执行即可, 具体步骤见 [docs/vendor-sdk.md](vendor-sdk.md)。
