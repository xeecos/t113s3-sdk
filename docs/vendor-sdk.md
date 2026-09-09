# 在 Docker 里使用全志官方 T113-S3 SDK (Longan / Tina Linux)

全志官方 SDK (Longan 为 buildroot 系, Tina 为 OpenWrt 系) 的构建工具链**只支持
x86_64 Linux**。在 Apple Silicon Mac 上有两个选择:

## 方案 A: x86_64 容器 + QEMU 模拟 (本机可用, 慢)

本机 colima 已带 `qemu-x86_64` 模拟器 (可用 `colima` 输出中的 emulators 确认)。

```bash
# 1. 构建 amd64 版编译镜像 (Dockerfile 双架构通用)
docker build --platform linux/amd64 -t t113-sdk-builder:amd64 -f docker/Dockerfile docker/

# 2. 解包官方 SDK 到 vendor/ 目录 (示例)
mkdir -p vendor && tar -xaf longan-t113.tar.* -C vendor/

# 3. 进入 amd64 容器编译
docker run --platform linux/amd64 --rm -it \
    -v "$PWD":/work -w /work/vendor/longan \
    t113-sdk-builder:amd64 bash

# 容器内 (以 Longan 为例)
source build/envsetup.sh
./build.sh menuconfig     # 选 board: t113_s3_xxx (具体名字以 SDK 为准)
./build.sh                # 编译
pack                      # 打包镜像 -> out/ 下的 *.img
```

> 模拟模式下编译速度约为原生 1/5 ~ 1/10, 内核级别编译可能需要数小时。
> 个别 SDK 自带的 32 位工具链组件还需在容器里补装
> `apt install lib32z1 libncurses5` 等。

## 方案 B: x86_64 服务器远程编译 (推荐, 快)

把本目录的 `docker/` 拷到任意 x86_64 Linux 服务器:

```bash
docker build -t t113-sdk-builder:amd64 -f docker/Dockerfile docker/
docker run --rm -it -v "$PWD":/work -w /work t113-sdk-builder:amd64 bash
```

官方 SDK 的拉取请走全志授权渠道 (客户支持门户 / FAE 提供的 encrypted 镜像),
解压后同样 `source build/envsetup.sh && ./build.sh`。

## SDK 产物烧写

官方 `pack` 出的镜像 (通常含 PhoenixSuit 格式) 与本环境打的 SD 卡镜像不同:
- SD 卡启动: 用 SDK 的 `dd` 镜像直接烧, 或 PhoenixCard 选"启动卡"
- 本环境的 `scripts/flash-sd.sh` 同样适用于任何 raw 镜像:
  `IMG=vendor/out/t113_linux_xxx.img make flash DEV=/dev/disk4`
