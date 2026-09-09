# hello: 应用示例 Makefile
# 由 scripts/build-apps.sh 驱动, 约定:
#   - OUTPUT 指向 out/apps/<name> (产物不入源码树)
#   - 静态链接: 最小 rootfs 不带 glibc 动态库
#   - CROSS_COMPILE 已在 config/board.env 导出
CROSS_COMPILE ?= arm-linux-gnueabihf-
CC            := $(CROSS_COMPILE)gcc
CFLAGS        ?= -O2 -Wall -Wextra
LDFLAGS       ?= -static

OUTPUT        ?= .
TARGET        := $(OUTPUT)/hello

all: $(TARGET)

$(TARGET): hello.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

.PHONY: all clean

clean:
	rm -f $(TARGET)
