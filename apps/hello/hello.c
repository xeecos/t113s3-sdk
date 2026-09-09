/*
 * hello: T113-S3 用户态示例程序
 *
 * 编译:  make apps          (scripts/build-apps.sh 批量编译 apps/ 下所有应用)
 * 产物:  out/apps/hello/hello  (armhf 静态链接)
 * 运行:  板子串口终端执行 /usr/bin/hello (rootfs 组装时已装入)
 */
#include <stdio.h>

int main(int argc, char *argv[])
{
	int i;

	printf("hello, world!\n");
	printf("running on T113-S3 (Cortex-A7 / armhf / busybox rootfs)\n");

	for (i = 1; i < argc; i++)
		printf("argv[%d] = %s\n", i, argv[i]);

	return 0;
}
