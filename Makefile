# ============================================================
# T113-S3 Docker 编译环境
# 常用命令:
#   make image   构建 Docker 编译镜像 (首次)
#   make shell   进入编译容器
#   make all     拉源码 + 编译 uboot/内核/rootfs + 打包 SD 镜像
#   make flash DEV=/dev/disk4   烧写 SD 卡 (macOS / Linux / WSL2)
# ============================================================
SHELL := /bin/bash
IMAGE ?= t113-sdk-builder:latest
# 宿主机代理 (下载慢/失败时): make <目标> PROXY=http://192.168.5.2:7890
#   macOS colima: 192.168.5.2 指向宿主机 127.0.0.1 (与 dockerd --host-gateway-ip 一致)
#   Docker Desktop: http://host.docker.internal:7890 ; Linux 容器: 127.0.0.1
PROXY ?=
NO_PROXY ?= localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,.tuna.tsinghua.edu.cn,.tsinghua.edu.cn,.gitee.com
ifneq ($(PROXY),)
RUN   := docker compose run --rm -e http_proxy=$(PROXY) -e https_proxy=$(PROXY) -e no_proxy=$(NO_PROXY) t113-build
else
RUN   := docker compose run --rm t113-build
endif

.PHONY: help image shell info fetch uboot kernel busybox apps rootfs rootfs-buildroot pack pack-spi all clean distclean flash

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
	@echo "  make apps             交叉编译 apps/ 用户应用 (hello 等, 装入 rootfs /usr/bin)"
	@echo "  make rootfs           组装最小根文件系统 (busybox)"
	@echo "  make rootfs-buildroot 用 Buildroot 构建完整根文件系统"
	@echo "  make pack             打包 SD 卡镜像 out/images/t113-sdcard.img"
	@echo "  make pack-spi         打包 SPI flash 镜像 out/images/t113-spi.img"
	@echo "                        (NOR / SPI NAND 由 config/board.env 的 SPI_FLASH_TYPE 决定)"
	@echo "  make all              fetch + uboot + kernel + busybox + apps + rootfs + pack"
	@echo
	@echo "  make flash DEV=/dev/diskN   烧写 SD 卡 (macOS)"
	@echo "  make flash DEV=/dev/sdX     烧写 SD 卡 (Linux / WSL2)"
	@echo "  make clean / distclean      清理输出 / 连源码一起清理"
	@echo
	@echo "Windows 宿主: 在 WSL2 中运行本项目 (安装与烧写见 docs/windows.md)"
	@echo
	@echo "常用变量: MIRROR=cn|official  APT_MIRROR=<镜像>  PROXY=<宿主机代理>  KERNEL_VER=  UBOOT_REF="
	@echo "          SPI_FLASH_TYPE=nand|nor  SPI_FLASH_SIZE_MB=<容量>  KERNEL_DTS=board|auto"

APT_MIRROR ?= archive.ubuntu.com
image:
	docker build --build-arg APT_MIRROR=$(APT_MIRROR) \
	  $(if $(PROXY),--build-arg http_proxy=$(PROXY) --build-arg https_proxy=$(PROXY) --build-arg no_proxy=$(NO_PROXY),) \
	  -t $(IMAGE) -f docker/Dockerfile docker/

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

apps:
	$(RUN) bash scripts/build-apps.sh

rootfs:
	$(RUN) bash scripts/build-rootfs.sh

rootfs-buildroot:
	$(RUN) bash scripts/build-rootfs-buildroot.sh

pack:
	$(RUN) bash scripts/pack-image.sh

pack-spi:
	$(RUN) bash scripts/pack-spi.sh

all: fetch uboot kernel busybox apps rootfs pack

# 烧写按宿主系统分发:
#   macOS  -> scripts/flash-sd.sh      (diskutil)
#   Linux  -> scripts/flash-linux.sh   (含 WSL2, 需先 usbipd 透传读卡器)
#   Windows 原生 (Git Bash/MINGW) -> 引导去 WSL2
flash:
	@uname_s="$$(uname -s)"; case "$$uname_s" in \
	  Darwin) bash scripts/flash-sd.sh $(DEV) ;; \
	  Linux)  bash scripts/flash-linux.sh $(DEV) ;; \
	  *) echo -e "Windows 宿主请勿直接在 PowerShell/Git Bash 烧写,\n请进入 WSL2 后运行: make flash DEV=/dev/sdX  (详见 docs/windows.md)"; exit 1 ;; \
	esac

clean:
	rm -rf out

distclean: clean
	rm -rf sources downloads .ccache
