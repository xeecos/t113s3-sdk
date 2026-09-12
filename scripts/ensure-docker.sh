#!/usr/bin/env bash
# 确保 Docker 可用 —— 被 Makefile 里所有依赖 Docker 的目标自动调用
#
# macOS: docker daemon 未运行时自动拉起 colima (推荐) 或 Docker Desktop,
#        colima 从未创建过时按 README 推荐配置创建 (6 CPU / 10G / 80G 磁盘)
# Linux/WSL2: daemon 不在时给出启动提示后退出 (不自动 sudo)
set -euo pipefail

log() { echo -e "\033[32m[docker]\033[0m $*"; }
die() { echo -e "\033[31m[error]\033[0m $*" >&2; exit 1; }

# daemon 已就绪 -> 直接返回 (这是日常路径, 开销仅一次 docker info)
if docker info >/dev/null 2>&1; then
  exit 0
fi

case "$(uname -s)" in
  Darwin)
    command -v docker >/dev/null 2>&1 \
      || die "未安装 docker CLI: brew install docker docker-compose (容器运行时用 colima 或 Docker Desktop)"

    if command -v colima >/dev/null 2>&1; then
      if [ -n "$(colima list 2>/dev/null | tail -n +2 | tr -d '[:space:]')" ]; then
        log "colima 未运行, 正在启动 (沿用已有配置)..."
        colima start
      else
        log "首次创建并启动 colima (6 CPU / 10G 内存 / 80G 磁盘, README 推荐配置)..."
        colima start --cpu 6 --memory 10 --disk 80
      fi
    elif [ -d "/Applications/Docker.app" ]; then
      log "Docker Desktop 未运行, 正在启动..."
      open -a Docker
    else
      die "既没有 colima 也没有 Docker.app, 安装其一即可:
        colima  : brew install colima docker docker-compose
        Desktop : https://www.docker.com/products/docker-desktop"
    fi

    # 等待 daemon 就绪 (colima 首次创建要几分钟, 这里最多等 5 分钟)
    for _ in $(seq 1 300); do
      if docker info >/dev/null 2>&1; then
        log "Docker 已就绪"
        exit 0
      fi
      sleep 1
    done
    die "等待 Docker 就绪超时 (5 分钟), 请手动检查: colima status 或 open -a Docker"
    ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      die "Docker daemon 未运行。WSL2 用户请先在 Windows 侧启动 Docker Desktop (并开启 WSL 集成)"
    fi
    die "Docker daemon 未运行。请先启动: sudo systemctl start docker"
    ;;
  *)
    die "Docker daemon 未运行, 且当前平台不支持自动启动, 请手动启动 Docker"
    ;;
esac
