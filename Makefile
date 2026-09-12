# ============================================================
# T113-S3 编译入口
#
# 默认使用宿主原生工具链 —— Linux 与 Windows(WSL2) 直接在 Ubuntu 里跑, 不需要 Docker。
# 只有 macOS 没有 Linux 工具链, 会自动回落到容器 (colima / Docker Desktop)。
#
# 常用命令:
#   make deps    安装编译依赖 (Ubuntu / WSL2, 首次一次即可)
#   make all     拉源码 + 编译 uboot/内核/rootfs + 打包 SD 镜像
#   make flash DEV=/dev/sdX   烧写 SD 卡 (Linux / WSL2; macOS 用 /dev/diskN)
# ============================================================
SHELL := /bin/bash
IMAGE ?= t113-sdk-builder:latest
APT_MIRROR ?= archive.ubuntu.com
# 宿主机代理 (下载慢/失败时): make <目标> PROXY=http://127.0.0.1:7890
#   原生 (Linux/WSL2) 直接继承本机环境变量; colima 用 192.168.5.2, Docker Desktop 用 http://host.docker.internal:7890
PROXY ?=
# 不用代理的域名 (本地 + 国内内核镜像直连更快; GitHub 等国际源走代理)
NO_PROXY ?= localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,.tuna.tsinghua.edu.cn,.tsinghua.edu.cn

# ---------- 构建引擎 ----------
#   native = 本机原生工具链 (Linux / WSL2 的 Ubuntu, 默认)
#   docker = 容器 (macOS 等没有 Linux 工具链的宿主)
UNAME_S := $(shell uname -s 2>/dev/null || echo unknown)
ENGINE  ?= auto
ifeq ($(ENGINE),auto)
  ifeq ($(UNAME_S),Darwin)
    ENGINE := docker
  else
    ENGINE := native
  endif
endif

# Windows 原生 shell (Git Bash / MSYS / Cygwin): 交叉工具链和打包工具都是 Linux 的,
# 这里只能提示 —— 真正的构建/烧写要在 WSL2 的 Ubuntu 里做 (见 docs/windows.md)。
ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
$(info [warn] 当前是 Windows 原生 shell ($(UNAME_S)), 本项目需要 Linux 工具链, 不要在这里构建。)
$(info        请打开 WSL 终端: cd /mnt/d/.../t113s3-sdk && make <目标>   (见 docs/windows.md))
$(info )
endif

ifeq ($(ENGINE),native)
# 原生: 直接执行, 环境变量按原样传给脚本 (config/board.env 里的 ${VAR:-默认} 生效)
RUN :=
NATIVE_TOOLS := gcc make git wget patch flex bison bc perl file ccache dtc mkimage \
                arm-linux-gnueabihf-gcc mke2fs debugfs mkfs.vfat mcopy sfdisk mksquashfs qemu-arm-static
# 原生模式下 PROXY 直接作为环境变量传给脚本 (git / wget 都认 http_proxy)
# WSL 里代理跑在 Windows 上时要用宿主网关地址: make proxy-hint 会打印出来
ifneq ($(PROXY),)
export http_proxy := $(PROXY)
export https_proxy := $(PROXY)
export no_proxy := $(NO_PROXY)
endif
else
ifneq ($(PROXY),)
RUN := docker compose run --rm -e http_proxy=$(PROXY) -e https_proxy=$(PROXY) -e no_proxy=$(NO_PROXY) t113-build
else
RUN := docker compose run --rm t113-build
endif
endif

# 与 docker-compose.yml 传递的环境变量保持一致; 原生模式下 make 需要显式导出
export MIRROR KERNEL_VER UBOOT_REF BUSYBOX_REF BOARD_DTS_NAME KERNEL_DTS KERNEL_DEFCONFIG \
       UBOOT_DTS UBOOT_DEFCONFIG SPI_ROOTFS SPI_FLASH_TYPE SPI_FLASH_SIZE_MB \
       SPI_UBOOT_SIZE SPI_DTB_SIZE SPI_KERNEL_SIZE JOBS

.PHONY: help check deps docker-ok image shell info proxy-hint fetch uboot kernel busybox apps rootfs rootfs-buildroot pack pack-spi all clean distclean flash

# 不带目标时打印帮助 (下面 BUILD_TARGETS 规则会抢走默认目标, 这里显式指定)
.DEFAULT_GOAL := help

# 构建类目标都先做一次依赖自检, 缺工具时立刻给出提示, 而不是编译到一半才报错
BUILD_TARGETS := fetch uboot kernel busybox apps rootfs rootfs-buildroot pack pack-spi
$(BUILD_TARGETS): check

help:
	@echo "T113-S3 编译入口 (原生工具链: Linux / WSL2; macOS 自动用容器)"
	@echo
	@echo "  构建引擎: $(ENGINE)   宿主: $(UNAME_S)"
	@echo
	@echo "  make deps             安装编译依赖 (Ubuntu / WSL2, 首次必做)"
	@echo "  make check            检查编译依赖是否齐全"
	@echo "  make proxy-hint       打印宿主代理地址 (拉源码慢时用)"
	@echo "  make image            构建容器镜像 (仅 macOS / ENGINE=docker 需要)"
	@echo "  make shell            进入编译 shell"
	@echo "                        (macOS 容器模式会先自动拉起 Docker/colima)"
	@echo "  make info             查看工具链版本"
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
	@echo "  make flash DEV=/dev/sdX     烧写 SD 卡 (Linux / WSL2; macOS 用 /dev/diskN)"
	@echo "  make clean / distclean      清理输出 / 连源码一起清理"
	@echo
	@echo "Windows 宿主: 在 WSL2 的 Ubuntu 里运行本项目 (原生, 不需要 Docker), 见 docs/windows.md"
	@echo
	@echo "常用变量: MIRROR=cn|official  JOBS=<并行数, 默认 nproc>  PROXY=<代理>"
	@echo "          KERNEL_VER=  UBOOT_REF=  KERNEL_DTS=board|auto  UBOOT_DTS=board|auto"
	@echo "          SPI_FLASH_TYPE=nand|nor  SPI_FLASH_SIZE_MB=<容量>  APT_MIRROR=<apt 镜像>"
	@echo "          ENGINE=docker|native  (强制切换构建引擎)"

# Docker 守卫 (仅容器模式): daemon 没跑时自动拉起 colima / Docker Desktop。
# 挂在 check/image/shell/info 前面, 因此 make all 的每一步构建都会先经过它;
# daemon 已就绪时开销只有一次 docker info (~30ms)
docker-ok:
	@[ "$(ENGINE)" != docker ] || bash scripts/ensure-docker.sh

# 依赖自检: 原生检查工具链是否齐全, 容器检查镜像是否已构建
check: docker-ok
ifeq ($(ENGINE),native)
	@case "$(UNAME_S)" in \
	  MINGW*|MSYS*|CYGWIN*) \
	    echo -e "\033[31m[error]\033[0m Windows 原生 shell 没有 Linux 工具链, 请在 WSL2 的 Ubuntu 里运行 make (见 docs/windows.md)"; \
	    exit 1 ;; \
	esac; \
	missing=""; for t in $(NATIVE_TOOLS); do command -v "$$t" >/dev/null 2>&1 || missing="$$missing $$t"; done; \
	if [ -n "$$missing" ]; then \
	  echo -e "\033[31m[error]\033[0m 缺少编译工具:$$missing"; \
	  echo "        安装依赖: make deps   (包清单见 docker/packages.txt)"; \
	  exit 1; \
	fi; \
	echo -e "\033[32m[build]\033[0m 编译依赖齐全 ($(UNAME_S) $$(uname -m))"
else
	@command -v docker >/dev/null 2>&1 || { echo -e "\033[31m[error]\033[0m 未找到 docker: brew install docker docker-compose && colima start"; exit 1; }
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || { echo -e "\033[31m[error]\033[0m 镜像 $(IMAGE) 不存在, 先运行 make image"; exit 1; }
endif

# 安装编译依赖 (原生模式; 包清单与 Dockerfile 共用 docker/packages.txt)
deps:
ifeq ($(ENGINE),native)
	@echo "安装编译依赖 (Ubuntu / WSL2, 需要 sudo)..."
	sudo apt-get update
	sudo apt-get install -y $$(grep -vE '^[[:space:]]*(#|$$)' docker/packages.txt | tr '\n' ' ')
	@$(MAKE) --no-print-directory check
else
	@echo "容器模式 (宿主 $(UNAME_S)): 依赖已内置在 $(IMAGE) 镜像里 —— 执行 make image"
endif

# 容器镜像 (macOS); 原生模式下 make image 等价于装依赖
image: docker-ok
ifeq ($(ENGINE),native)
	@$(MAKE) --no-print-directory deps
else
	docker build --build-arg APT_MIRROR=$(APT_MIRROR) \
	  $(if $(PROXY),--build-arg http_proxy=$(PROXY) --build-arg https_proxy=$(PROXY) --build-arg no_proxy=$(NO_PROXY),) \
	  -t $(IMAGE) -f docker/Dockerfile docker/
endif

shell: docker-ok
ifeq ($(ENGINE),native)
shell:
	@echo "原生模式: 在本项目目录开 shell (工具链变量已按 config/board.env 载入)"
	@bash -c 'source scripts/env.sh >/dev/null 2>&1 || true; set +u +e +o pipefail; exec bash'
else
shell:
	$(RUN)
endif

info: docker-ok
	$(RUN) bash -c 'echo "宿主   : $(UNAME_S) ($(ENGINE)) / $$(uname -m)"; \
	  echo "host gcc: $$(gcc --version | head -1 | awk "{print \$$3}")"; \
	  echo "armhf gcc: $$(arm-linux-gnueabihf-gcc --version | head -1 | awk "{print \$$4}")"; \
	  echo "dtc     : $$(dtc --version | awk "{print \$$2}")"; \
	  echo "ccache  : $$(ccache --version | head -1 | awk "{print \$$3}")"'

# WSL 里代理通常跑在 Windows 上, 这时要用宿主网关地址
# (WSL2 是 NAT 网络, 127.0.0.1 指向 WSL 自己, 够不到 Windows 上的代理)
proxy-hint:
	@case "$(UNAME_S)" in \
	  Linux) ip="$$(ip route show default 2>/dev/null | awk '{print $$3}')"; \
	         if [ -n "$$ip" ]; then \
	           echo "宿主代理用法 (WSL 内的 127.0.0.1 不是 Windows):"; \
	           echo "  PROXY=http://$$ip:7890 make fetch"; \
	         else echo "取不到默认网关, 请手动确认代理地址"; fi ;; \
	  Darwin) echo "macOS: colima 用 http://192.168.5.2:7890, Docker Desktop 用 http://host.docker.internal:7890" ;; \
	  *) echo "请在 WSL2 的 Ubuntu 里运行本项目 (见 docs/windows.md)" ;; \
	esac
	@echo "也可以直接: export http_proxy=http://<地址>:7890 https_proxy=\$$http_proxy"
	@echo "国际源慢/卡时还可换源: MIRROR=official make fetch"

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
