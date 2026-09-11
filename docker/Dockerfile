# T113-S3 交叉编译环境 (Ubuntu 22.04, 支持 arm64/amd64 双架构)
#
# 仅 macOS 需要这个镜像 (Linux / WSL2 请直接用原生工具链: make deps, 见 docs/windows.md)。
#
# 默认构建本机架构镜像 (Apple Silicon 上为 linux/arm64 原生, 编译速度快)。
# 如需运行全志官方 x86_64 SDK (Longan/Tina), 用 amd64 构建:
#   docker build --platform linux/amd64 -t t113-sdk-builder:amd64 -f docker/Dockerfile docker/
# 详见 docs/vendor-sdk.md
FROM ubuntu:22.04

# 中国网络环境可用: make image APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
ARG APT_MIRROR=archive.ubuntu.com
# 构建期下载走宿主机代理 (下载慢/失败时): make image PROXY=http://192.168.5.2:7890
# (macOS colima 的宿主机代理地址; Docker Desktop 用 http://host.docker.internal:7890)
ARG http_proxy=
ARG https_proxy=
ARG no_proxy=

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

# 包清单与 make deps 共用一份 (docker/packages.txt), 两边的编译环境保持一致
COPY packages.txt /usr/local/share/t113-packages.txt
RUN sed -i "s|archive.ubuntu.com|${APT_MIRROR}|g; s|security.ubuntu.com|${APT_MIRROR}|g" /etc/apt/sources.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        $(grep -vE '^[[:space:]]*(#|$)' /usr/local/share/t113-packages.txt | tr '\n' ' ') \
    && locale-gen en_US.UTF-8 zh_CN.UTF-8 \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && rm -rf /var/lib/apt/lists/*

# 默认交叉编译 armv7 (Cortex-A7); 容器内脚本会显式传参, 这里仅作 shell 里的默认值
ENV ARCH=arm \
    CROSS_COMPILE=arm-linux-gnueabihf- \
    CCACHE_DIR=/work/.ccache \
    KBUILD_BUILD_USER=builder \
    KBUILD_BUILD_HOST=t113-sdk

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
