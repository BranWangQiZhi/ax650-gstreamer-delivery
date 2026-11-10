/*
 * glibc230_compat.c - 为 glibc 2.30 目标板提供 glibc 2.32/2.33 符号兼容层
 *
 * 背景: AX650 SDK 的交叉工具链 (gcc-arm-10.3-2021.07) sysroot 是 glibc 2.33,
 *       而开发板 rootfs 是 glibc 2.30, 用新工具链编出的库会引用
 *       stat64/lstat64/fstat64@GLIBC_2.33 和 pthread_sigmask@GLIBC_2.32,
 *       在板子上直接报 "version `GLIBC_2.33' not found"。
 *
 * 做法: 用系统调用直接实现这几个符号, 并用 version script 打上 2.32/2.33 版本号,
 *       让板子上以 LD_PRELOAD 方式优先解析到本库。
 *
 * 编译 (见 build.sh):
 *   aarch64-none-linux-gnu-gcc -shared -fPIC -O2 glibc230_compat.c \
 *       -o libglibc230_compat.so -Wl,--version-script=glibc230_compat.map
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* 直接走 syscall, 不依赖 libc 的 stat 包装, 避免符号递归 */
int stat64(const char *path, struct stat64 *buf) {
  return (int)syscall(SYS_newfstatat, AT_FDCWD, path, buf, 0);
}

int lstat64(const char *path, struct stat64 *buf) {
  return (int)syscall(SYS_newfstatat, AT_FDCWD, path, buf, AT_SYMLINK_NOFOLLOW);
}

int fstat64(int fd, struct stat64 *buf) {
  return (int)syscall(SYS_fstat, fd, buf);
}

/* glibc 2.32 中 pthread_sigmask 的版本号变化, 直接映射到 rt_sigprocmask 系统调用 */
int pthread_sigmask(int how, const sigset_t *set, sigset_t *oldset) {
  return (int)syscall(SYS_rt_sigprocmask, how, set, oldset, (size_t)8);
}
