# dpdk-19.11 armv8 l2fwd 在某 arm 内核上无法运行问题
## 问题描述
编译 dpdk-19.11 arm 版本的 l2fwd，在指定的 arm 内核上运行，有如下报错信息：

```bash
EAL: Detected 16 lcore(s)
EAL: Detected 1 NUMA nodes
EAL: Multi-process socket /var/run/dpdk/rte/mp_socket
EAL: Selected IOVA mode 'PA'
EAL: Probing VFIO support...
EAL: error allocating rte services array
EAL: FATAL: rte_service_init() failed
EAL: rte_service_init() failed
EAL: Error - exiting with code: 1
  Cause: Invalid EAL arguments
```
关键报错：

**EAL: error allocating rte services array**

## 确认问题
1. hugepage 正常配置，hugetlbfs 正常挂载
2. dpdk-16.04 的 l2fwd 能够正常运行

查看代码确认问题为**在创建 rte services 数组的时候申请内存失败**！
## strace 跟踪获取到的结果
strace 跟踪 l2fwd 程序执行，摘录如下关键过程：

```strace
openat(AT_FDCWD, "/dev/hugepages", O_RDONLY) = 23
flock(23, LOCK_EX)                      = 0
openat(AT_FDCWD, "/dev/hugepages/rtemap_0", O_RDWR|O_CREAT, 0600) = 24
flock(24, LOCK_SH|LOCK_NB)              = 0
ftruncate(24, 2097152)                  = 0
mmap(0x100200000, 2097152, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_FIXED|MAP_POPULATE, 24, 0) = 0x100200000
rt_sigprocmask(SIG_BLOCK, NULL, [], 8)  = 0
openat(AT_FDCWD, "/proc/self/pagemap", O_RDONLY) = 25
lseek(25, 8392704, SEEK_SET)            = 8392704
read(25, "\0\0z\0\0\0\0\241", 8)        = 8
close(25)                               = 0
get_mempolicy(0x7fffffce24, NULL, 0, 0x100200000, MPOL_F_NODE|MPOL_F_ADDR) = -1 ENOSYS (Function not implemented)
munmap(0x100200000, 2097152)            = 0
mmap(0x100200000, 2097152, PROT_READ, MAP_PRIVATE|MAP_FIXED|MAP_ANONYMOUS, -1, 0) = 0x100200000
flock(24, LOCK_EX|LOCK_NB)              = 0
unlinkat(AT_FDCWD, "/dev/hugepages/rtemap_0", 0) = 0
close(24)                               = 0
```
上述系统调用在映射第一个大页，明显的异常内容如下：

```strace
get_mempolicy(0x7fffffce24, NULL, 0, 0x100200000, MPOL_F_NODE|MPOL_F_ADDR) = -1 ENOSYS (Function not implemented)
```
此信息表明当前内核不支持 **get_mempolicy** 系统调用。

## 提问环节
1. get_mempolicy 在哪里被调用？

	阅读代码确认在映射大页的过程中会调用 get_mempolicy，当失败后会使用默认值。

2. 是否有配置关闭相关逻辑？
	CONFIG_RTE_EAL_NUMA_AWARE_HUGEPAGES 能够用来控制这部分代码逻辑。
3. get_mempolicy 调用失败为什么不退出？
	调用失败后会使用缺省值！
## get_mempolicy 是干嘛的？
man get_mempolicy 的部分信息如下：

```manual
GET_MEMPOLICY(2)                                   Linux Programmer's Manual                                   GET_MEMPOLICY(2)

NAME
       get_mempolicy - retrieve NUMA memory policy for a thread

SYNOPSIS
       #include <numaif.h>

       long get_mempolicy(int *mode, unsigned long *nodemask,
                         unsigned long maxnode, void *addr,
                         unsigned long flags);

       Link with -lnuma.
```

## 解决方法
armv8 的 .config 文件中关闭　**CONFIG_RTE_EAL_NUMA_AWARE_HUGEPAGES** 配置后重新编译，测试正常。

## 关闭 RTE_EAL_NUMA_AWARE_HUGEPAGES 的合理性
NUMA_AWARE_HUGEPAGES 的修改能够从 [[dpdk-dev] [PATCH v7 1/2] mem: balanced allocation of hugepages](http://mails.dpdk.org/archives/dev/2017-June/068386.html) 中找到。

浏览 patch 内容，获取到如下信息：

```patch
diff --git a/config/defconfig_arm64-armv8a-linuxapp-gcc b/config/defconfig_arm64-armv8a-linuxapp-gcc
index 9f32766..2c67cdc 100644
--- a/config/defconfig_arm64-armv8a-linuxapp-gcc
+++ b/config/defconfig_arm64-armv8a-linuxapp-gcc
@@ -47,6 +47,9 @@ CONFIG_RTE_TOOLCHAIN_GCC=y
 # to address minimum DMA alignment across all arm64 implementations.
 CONFIG_RTE_CACHE_LINE_SIZE=128
 
+# Most ARMv8 systems doesn't support NUMA
+CONFIG_RTE_EAL_NUMA_AWARE_HUGEPAGES=n
+
```
大部分 ARMv8 系统并不支持 numa，缺省配置关闭。.config 中同步 ARMv8 的默认配置是合理的！