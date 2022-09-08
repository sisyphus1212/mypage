# __thread 定义的每线程数据使用及其内部原理分析
## 前言
最近搞新 dpdk 版本适配工作时遇到了如下问题：

1. 某驱动中单独定义了一些**每线程数据**，这些数据在初始化过程中被赋值，后续获取信息等操作都依赖这一数据
2. 我们的程序中单独创建了一个线程定时获取网卡的收发包统计并输出到文件中，这个线程中没有初始化驱动中定义的每线程数据，在获取数据的时候会触发段错误

调试确认问题后，封装了一个接口，在收发包统计输出线程中也初始化了驱动中定义的每线程数据，问题得到解决！

趁此机会，研究了下每线程数据的一些使用方法与原理，在本文中记录一下。

## 每线程数据示例 demo
```c
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

__thread int lcore_id;

void* worker(void* arg)
{
	lcore_id = (int)arg;
	
	printf("entering lcore %d\n", lcore_id);

	return NULL;
}

int main(void){
	pthread_t pid1;
	pthread_t pid2;

	pthread_create(&pid1, NULL, worker, (void *)1);
	pthread_create(&pid2, NULL, worker, (void *)2);
	
	pthread_join(pid1, NULL);
	pthread_join(pid2, NULL);

	return 0;
}
```
将上述源码保存为 lcore.c，执行 gcc lcore.c -o lcore -lpthread 编译。运行 lcore 终端打印如下信息：

```bash
[longyu@debian-10:17:16:39] tmp $ ./lcore 
entering lcore 1
entering lcore 2
```
可以确定，每一个线程都有自己单独的一份 **lcore_id**。

## 每线程数据是如何实现的?
### 1. 查看头文件中的定义
头文件中没找到 __thread 的定义！

### 2. 查看 map 文件中存储布局
执行 gcc ./lcore.c -Wl,-Map=lcore.map -o lcore -lpthread 生成 map 文件，搜索 lcore_id，得到如下信息：
```map
	 *(.tbss .tbss.* .gnu.linkonce.tb.*)
 	.tbss          0x0000000000003dd8        0x4 /tmp/ccqjk28I.o
    	            0x0000000000003dd8                lcore_id
```
可以确定 lcore_id 在 .tbss 中被分配，大小为 4 字节。
	
### 3. 查看默认链接脚本
```link
  /* Thread Local Storage sections  */
  .tdata	  :
   {
     PROVIDE_HIDDEN (__tdata_start = .);
     *(.tdata .tdata.* .gnu.linkonce.td.*)
   }
  .tbss		  : { *(.tbss .tbss.* .gnu.linkonce.tb.*) *(.tcommon) }
```
默认的链接脚本中，.tdata 与 .tbss section 都有定义，区别在于一个存放初始化的内容，一个存放未初始化的内容。

### 4. 反汇编 worker 函数
```assemble
0000000000001155 <worker>:
    1155:       55                      push   %rbp
    1156:       48 89 e5                mov    %rsp,%rbp
    1159:       48 83 ec 10             sub    $0x10,%rsp
    115d:       48 89 7d f8             mov    %rdi,-0x8(%rbp)
    1161:       48 8b 45 f8             mov    -0x8(%rbp),%rax
    1165:       64 89 04 25 fc ff ff    mov    %eax,%fs:0xfffffffffffffffc
    116c:       ff 
    116d:       64 8b 04 25 fc ff ff    mov    %fs:0xfffffffffffffffc,%eax
    1174:       ff 
    1175:       89 c6                   mov    %eax,%esi
    1177:       48 8d 3d 86 0e 00 00    lea    0xe86(%rip),%rdi        # 2004 <_IO_stdin_used+0x4>
    117e:       b8 00 00 00 00          mov    $0x0,%eax
    1183:       e8 b8 fe ff ff          callq  1040 <printf@plt>
    1188:       b8 00 00 00 00          mov    $0x0,%eax
    118d:       c9                      leaveq 
    118e:       c3                      retq   
```

源码 lcore_id = (int)arg; 对应的汇编代码如下：
```assemble
    1165:       64 89 04 25 fc ff ff    mov    %eax,%fs:0xfffffffffffffffc
```
eax 寄存器中存放从线程的栈中获取到的 arg 的值，此值被存放到段寄存器 fs - 4 位置处。

### 5. strace 跟踪程序执行
strace 跟踪获取到下面这些关键信息：

```strace
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libpthread.so.0", O_RDONLY|O_CLOEXEC) = 3
......
arch_prctl(ARCH_SET_FS, 0x7f65b0e40740) = 0
set_tid_address(0x7f65b0e40a10)         = 27705
set_robust_list(0x7f65b0e40a20, 24)     = 0
......
clone(child_stack=0x7f65b0e3efb0, flags=CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SYSVSEM|CLONE_SETTLS|CLONE_PARENT_SETTID|CLONE_CHILD_CLEARTID, parent_tidptr=0x7f65b0e3f9d0, tls=0x7f65b0e3f700, child_tidptr=0x7f65b0e3f9d0) = 27706
......
clone(child_stack=0x7f65b063dfb0, flags=CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SYSVSEM|CLONE_SETTLS|CLONE_PARENT_SETTID|CLONE_CHILD_CLEARTID, parent_tidptr=0x7f65b063e9d0, tls=0x7f65b063e700, child_tidptr=0x7f65b063e9d0) = 27707
```
列举的这几个系统调用非常关键，两个 clone 系统调用创建两个线程，在此之前的系统调用用来设定主线程。

## arch_prctl 系统调用
man arch_prctl 得到如下重要信息：
```c
SYNOPSIS
       #include <asm/prctl.h>
       #include <sys/prctl.h>

       int arch_prctl(int code, unsigned long addr);
       int arch_prctl(int code, unsigned long *addr);

DESCRIPTION
       arch_prctl() sets architecture-specific process or thread state.  code selects a subfunction and passes argument addr to it; addr is interpreted as either an un‐
       signed long for the "set" operations, or as an unsigned long *, for the "get" operations.

       Subfunctions for x86-64 are:

       ARCH_SET_FS
              Set the 64-bit base for the FS register to addr.

       ARCH_GET_FS
              Return the 64-bit base value for the FS register of the current thread in the unsigned long pointed to by addr.

       ARCH_SET_GS
              Set the 64-bit base for the GS register to addr.

       ARCH_GET_GS
              Return the 64-bit base value for the GS register of the current thread in the unsigned long pointed to by addr.
```
ARCH_SET_FS 是用来设定 fs 寄存器的值，有了这个信息再加上 clone 中的 CLONE_SETTLS flag 设定，我判断上述系统调用中 arch_prctl 是针对主线程的特定逻辑！

为了验证我的猜想，我将源码修改如下：

```c
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

__thread int lcore_id;

void* worker(void* arg)
{
	lcore_id = (int)arg;
	
	printf("lcore_id is %d, &lcore_id is %p\n", lcore_id, &lcore_id);

	return NULL;
}

int main(void){
	pthread_t pid1;
	pthread_t pid2;

	pthread_create(&pid1, NULL, worker, (void *)1);
	pthread_create(&pid2, NULL, worker, (void *)2);
	
	pthread_join(pid1, NULL);
	pthread_join(pid2, NULL);
	
	printf("main thread &lcore_id is %p\n", &lcore_id);
	return 0;
}
```
继续使用 strace 跟踪，并在 strace log 中检索 arch_prctl 与 clone 系统调用的参数，得到如下信息：

```bash
[longyu@debian-10:22:08:25] tmp $ strace ./lcore 2>strace.txt
lcore_id is 1, &lcore_id is 0x7ff52b15e6fc
lcore_id is 2, &lcore_id is 0x7ff52a95d6fc
main thread &lcore_id is 0x7ff52b15f73c
[longyu@debian-10:22:08:32] tmp $ grep 'arch_prctl' ./strace.txt 
arch_prctl(ARCH_SET_FS, 0x7ff52b15f740) = 0
[longyu@debian-10:22:08:40] tmp $ grep 'clone' ./strace.txt 
clone(child_stack=0x7ff52b15dfb0, flags=CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SYSVSEM|CLONE_SETTLS|CLONE_PARENT_SETTID|CLONE_CHILD_CLEARTID, parent_tidptr=0x7ff52b15e9d0, tls=0x7ff52b15e700, child_tidptr=0x7ff52b15e9d0) = 30996
clone(child_stack=0x7ff52a95cfb0, flags=CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SYSVSEM|CLONE_SETTLS|CLONE_PARENT_SETTID|CLONE_CHILD_CLEARTID, parent_tidptr=0x7ff52a95d9d0, tls=0x7ff52a95d700, child_tidptr=0x7ff52a95d9d0) = 30997
```
整理得到如下表格：

| 线程        | lcore_id 地址  | fs、tls addr   | lcore_id 地址与 fs、tls addr 的关系 |
| ----------- | -------------- | -------------- | ----------------------------------- |
| main thread | 0x7ff52b15f73c | 0x7ff52b15f740 | fs - 4                              |
| lcore_id 1  | 0x7ff52b15e6fc | 0x7ff52b15e700 | tls addr - 4                        |
| lcore_id 2  | 0x7ff52a95d6fc | 0x7ff52a95d700 | tls addr -4                         |

## 获取线程的 fs 寄存器内容
为了进一步验证，我在 worker 函数中调用 arch_prctl 获取当前线程 fs 寄存器值，继续修改代码，patch 如下：
```patch
diff --git a/./lcore-1.c b/lcore.c
index 49e65fe..dff3041 100644
--- a/./lcore-1.c
+++ b/lcore.c
@@ -1,14 +1,19 @@
 #include <pthread.h>
 #include <stdio.h>
 #include <unistd.h>
+#include <asm/prctl.h>
+#include <sys/prctl.h>
 
 __thread int lcore_id;
 
 void* worker(void* arg)
 {
        lcore_id = (int)arg;
-       
-       printf("lcore_id is %d, &lcore_id is %p\n", lcore_id, &lcore_id);
+       unsigned long *fs;
+
+       arch_prctl(ARCH_GET_FS, &fs);
+
+       printf("lcore_id is %d, &lcore_id is %p, fs is %p\n", lcore_id, &lcore_id, fs);
 
        return NULL;
 }
```
执行示例：
```bash
lcore_id is 1, &lcore_id is 0x7f8a7839b6fc, fs is 0x7f8a7839b700
lcore_id is 2, &lcore_id is 0x7f8a77b9a6fc, fs is 0x7f8a77b9a700
main thread &lcore_id is 0x7f8a7839c73c
```
能够确定创建的两个线程，其 fs 寄存器 -4 就是 lcore_id 变量的地址，联系上文反汇编的结果，可以确定 0xfffffffffffffffc 对应的值就是 -4，**-4 正是 0xfffffffffffffffc 的二进制补码代表的值**！

## 每线程数据的实现原理猜想
根据上文的描述信息，对 __thread 的原理，我有如下猜想：

1. gcc 负责解析 __thread 关键字，并通过在 .tdata、 .tbss 段中添加信息来声明需要创建的每线程数据并生成访问每线程数据的汇编码。
2. 链接器负责确定需要创建的所有的每线程数据的大小，通过 .tdata 与 .tbss 段段大小确定。
3. 对于每个线程而言，基地址如 fs 段基址是不同的，但是访问 tls 的偏移量固定，切换到每个线程中时，fs 寄存器使用每线程独立的地址，这就实现了每线程数据。

## 每线程数据创建的真实过程
我上面的猜想部分符合程序中定义的每线程数据的创建与访问过程，但这只是每线程数据使用场景中的一种。

下面这个链接中详细描述了四种 tls 场景的不同实现原理：
[A Deep dive into (implicit) Thread Local Storage](https://chao-tic.github.io/blog/2018/12/25/tls#fnref:c-tricks) 

在进一步研究之前，需要先阅读下 ld.so 处理过程的代码，这部分代码我在写 [动态链接 lazy binding 的原理与 GOT 表的保留表项](https://blog.csdn.net/Longyu_wlz/article/details/109633275?ops_request_misc=%257B%2522request%255Fid%2522%253A%2522161875653916780262585237%2522%252C%2522scm%2522%253A%252220140713.130102334.pc%255Fblog.%2522%257D&request_id=161875653916780262585237&biz_id=0&utm_medium=distribute.pc_search_result.none-task-blog-2~blog~first_rank_v2~rank_v29-3-109633275.pc_v2_rank_blog_default&utm_term=%E5%8A%A8%E6%80%81) 这篇文章的时候粗浅瞅了瞅，其过程相对复杂，link_map 数据结构相对庞大，是一块硬骨头。

不过要想掌握动态链接程序加载过程的全貌，研究动态库加载器执行过程是必经之路！