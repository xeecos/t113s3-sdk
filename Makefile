# ============================================================
# T113-S3 Docker 编译环境
# 常用命令:
#   make image   构建 Docker 编译镜像 (首次)
#   make shell   进入编译容器
#   make all     拉源码 + 编译 uboot/内核/rootfs + 打包 SD 镜像
#   make flash DEV=/dev/disk4   烧写 SD 卡
# ============================================================
SHELL := /bin/bash
IMAGE ?= t113-sdk-builder:latest
RUN   := docker compose run --rm t113-build

.PHONY: help image shell info fetch uboot kernel busybox rootfs rootfs-buildroot pack pack-spi all clean distclean flash

help:
	@echo "T113-S3 Docker 编译环境"
	@echo
	@echo "  make image            构建 Docker 编译镜像 (首次必做)"
	@echo "  make shell            进入编译容器交互 shell"
	@echo "  make info             查看容器工具链版本"
	@echo
	@echo "  make fetch            拉取 U-Boot / Linux / busybox 源码"
	@echo "  make uboot            编译 U-Boot"
	@echo "  make kernel           编译内核 (zImage + dtb)"
	@echo "  make busybox          交叉编译静态 busybox"
	@echo "  make rootfs           组装最小根文件系统 (busybox)"
	@echo "  make rootfs-buildroot 用 Buildroot 构建完整根文件系统"
	@echo "  make pack             打包 SD 卡镜像 out/images/t113-sdcard.img"
	@echo "  make pack-spi         打包 SPI NOR 镜像 out/images/t113-spi.img"
	@echo "  make all              fetch + uboot + kernel + busybox + rootfs + pack"
	@echo
	@echo "  make flash DEV=/dev/diskN   烧写 SD 卡 (macOS)"
	@echo "  make clean / distclean      清理输出 / 连源码一起清理"
	@echo
	@echo "常用变量: MIRROR=cn|official  APT_MIRROR=<镜像>  KERNEL_VER=  UBOOT_REF="

image:
	docker build -t $(IMAGE) -f docker/Dockerfile docker/

shell:
	$(RUN)

info:
	$(RUN) bash -c 'arm-linux-gnueabihf-gcc --version | head -1; dtc --version; mkimage -V 2>/dev/null || true'

fetch:
	$(RUN) bash scripts/fetch-sources.sh

uboot:
	$(RUN) bash scripts/build-uboot.sh

kernel:
	$(RUN) bash scripts/build-kernel.sh

busybox:
	$(RUN) bash scripts/build-busybox.sh

rootfs:
	$(RUN) bash scripts/build-rootfs.sh

rootfs-buildroot:
	$(RUN) bash scripts/build-rootfs-buildroot.sh

pack:
	$(RUN) bash scripts/pack-image.sh

pack-spi:
	$(RUN) bash scripts/pack-spi.sh

all: fetch uboot kernel busybox rootfs pack

flash:
	bash scripts/flash-sd.sh $(DEV)

clean:
	rm -rf out

distclean: clean
	rm -rf sources downloads .ccache
