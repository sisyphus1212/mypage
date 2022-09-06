# dpdk-16.04 监听 uio 文件检测中断的示例 demo 与内部实现解析
## 前言
在 [Eal:Error reading from file descriptor 33: Input/output error](https://blog.csdn.net/Longyu_wlz/article/details/121443906) 这篇文章中，我描述了 VMWARE 环境中 dpdk 程序使用 82545EM 虚拟网卡时，一直打印 Input/output error 的问题。

这个问题最终通过修改 igb_uio 的代码修复，修复后我不禁在想用户态是怎样工作的？以前大概知道是通过 epoll 来监控 uio 文件的，却并不清楚具体的流程。

在本文中，我使用 dpdk-16.04 中断线程模拟 demo 来进一步研究 dpdk 通过 uio 文件监控网卡中断事件的关键过程。
## dpdk 监听 uio 文件检测中断的示例 demo
demo 运行机器内核信息：

```bash
longyu@debian:~/epoll$ uname -a
Linux debian 4.19.0-18-amd64 #1 SMP Debian 4.19.208-1 (2021-09-29) x86_64 GNU/Linux
```

网卡绑定信息：

```bash
longyu@debian:~/epoll$ sudo python ../dpdk-16.04/tools/dpdk_nic_bind.py -s

Network devices using DPDK-compatible driver
============================================
0000:02:05.0 '82545EM Gigabit Ethernet Controller (Copper)' drv=igb_uio unused=e1000
```
为了解决编译问题，对 dpdk-16.04 igb_uio.c 代码做了如下修改：

```c
--- lib/librte_eal/linuxapp/igb_uio/igb_uio.c  
+++ lib/librte_eal/linuxapp/igb_uio/igb_uio.c
@@ -442,7 +442,7 @@
        case RTE_INTR_MODE_MSIX:
                /* Only 1 msi-x vector needed */
                msix_entry.entry = 0;
-               if (pci_enable_msix(dev, &msix_entry, 1) == 0) {
+               if (pci_enable_msix_range(dev, &msix_entry, 1, 1) == 0) {s
```
demo 程序摘自 dpdk-16.04 并进行了一些简化，源码如下：

```c
#include <stdio.h>
#include <stdarg.h>
#include <errno.h>
#include <sys/epoll.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>

static void eal_intr_handle_interrupts(int pfd, unsigned totalfds);

#define rte_panic(...) rte_panic_(__func__, __VA_ARGS__, "dummy")
#define rte_panic_(func, format, ...) __rte_panic(func, format "%.0s", __VA_ARGS__)

/* call abort(), it will generate a coredump if enabled */
static void __rte_panic(const char *funcname, const char *format, ...)
{
  va_list ap;

  va_start(ap, format);
  vprintf(format, ap);
  va_end(ap);
  abort();
}

static void epoll_uio_file(int fd)
{
  struct epoll_event ev;

  for (;;) {
    unsigned numfds = 0;

    /* create epoll fd */
    int pfd = epoll_create(1);
    if (pfd < 0)
      rte_panic("Cannot create epoll instance\n");

    ev.events = EPOLLIN | EPOLLPRI;
    ev.data.fd = fd;

    if (epoll_ctl(pfd, EPOLL_CTL_ADD, fd, &ev) < 0){
      rte_panic("Error adding fd %d epoll_ctl, %s\n",
                fd, strerror(errno));
    } else {
      numfds++;
    }

    /* serve the interrupt */
    eal_intr_handle_interrupts(pfd, numfds);

    /**
     * when we return, we need to rebuild the
     * list of fds to monitor.
     */
    close(pfd);
  }
}

#define EAL_INTR_EPOLL_WAIT_FOREVER -1

static void
eal_intr_handle_interrupts(int pfd, unsigned totalfds)
{
  struct epoll_event events[totalfds];
  int nfds = 0;
  int bytes_read;
  char buf[1024];

  for(;;) {
    nfds = epoll_wait(pfd, events, totalfds,
                      EAL_INTR_EPOLL_WAIT_FOREVER);
    /* epoll_wait fail */
    if (nfds < 0) {
      if (errno == EINTR)
        continue;
      printf("epoll_wait returns with fail\n");
      return;
    }
    /* epoll_wait timeout, will never happens here */
    else if (nfds == 0)
      continue;

    /* epoll_wait has at least one fd ready to read */
    bytes_read = 1;
    bytes_read = read(events[0].data.fd, &buf, bytes_read);

    if (bytes_read < 0) {
      if (errno == EINTR || errno == EWOULDBLOCK)
        continue;

      printf("Error reading from file "
              "descriptor %d: %s\n",
              events[0].data.fd,
              strerror(errno));
    }
  }
}

#define UIO_PATH "/dev/uio0"

int main(void)
{
  int fd;

  fd = open(UIO_PATH, O_RDWR);

  if (fd < 0) {
    rte_panic("open %s failed\n", UIO_PATH);
  }

  epoll_uio_file(fd);

  return 0;
}
```
上述 demo 的关键流程如下：
1. 打开绑定到 igb_uio 驱动的网卡接口生成的 uio 文件
2. 使用 1 中打开 uio 文件获取的 fd 为参数调用 epoll_uio_file 函数
3. epoll_uio_file 函数创建一个 epoll 事件，并将传入的 fd 添加到监控列表中
4. epoll_uio_file 随后调用 eal_intr_handle_interrupts 函数，eal_intr_handle_interrupts 函数中调用 epoll_wait 监控事件，当有事件发生时，调用 read 函数读取事件内容

## demo 运行信息
运行结果 log 信息如下：

```c
Error reading from file descriptor 3: Input/output error
Error reading from file descriptor 3: Input/output error
Error reading from file descriptor 3: Input/output error
Error reading from file descriptor 3: Input/output error
Error reading from file descriptor 3: Input/output error
Error reading from file descriptor 3: Input/output error
```
输出信息表明复现出了与 [Eal:Error reading from file descriptor 33: Input/output error](https://blog.csdn.net/Longyu_wlz/article/details/121443906) 一样的问题。

**strace 跟踪信息如下：**

```c
openat(AT_FDCWD, "/dev/uio0", O_RDWR)   = 3
epoll_create(1)                         = 4
epoll_ctl(4, EPOLL_CTL_ADD, 3, {EPOLLIN|EPOLLPRI, {u32=3, u64=3}}) = 0
epoll_wait(4, [{EPOLLIN|EPOLLPRI|EPOLLERR|EPOLLHUP, {u32=3, u64=3}}], 1, -1) = 1
read(3, 0x7ffcdaac3480, 1)              = -1 EIO (Input/output error)
fstat(1, {st_mode=S_IFCHR|0620, st_rdev=makedev(0x88, 0), ...}) = 0
brk(NULL)                               = 0x562f29f41000
brk(0x562f29f62000)                     = 0x562f29f62000
write(1, "Error reading from file descript"..., 57) = 57
epoll_wait(4, [{EPOLLIN|EPOLLPRI|EPOLLERR|EPOLLHUP, {u32=3, u64=3}}], 1, -1) = 1
read(3, 0x7ffcdaac3480, 1)              = -1 EIO (Input/output error)
write(1, "Error reading from file descript"..., 57) = 57
```
## dpdk-16.04 监听 uio 文件检测中断的一些功能与实现
### 1. 一个接口支持注册多个中断回调
每个中断源之间使用链表链起来，每个中断源还有有一个中断回调链表，一个中断回调的定义是回调函数+参数，多个中断回调使用链表链起来。

中断回调与中断源结构的定义如下：
```c
struct rte_intr_callback {
	TAILQ_ENTRY(rte_intr_callback) next;
	rte_intr_callback_fn cb_fn;  /**< callback address */
	void *cb_arg;                /**< parameter for callback */
};

struct rte_intr_source {
	TAILQ_ENTRY(rte_intr_source) next;
	struct rte_intr_handle intr_handle; /**< interrupt handle */
	struct rte_intr_cb_list callbacks;  /**< user callbacks */
	uint32_t active;
};
```

dpdk-16.04 没有检查中断回调的唯一性，存在注册多个相同中断回调的情况。
### 2. 支持高效的事件监控，及时捕获处理中断事件

dpdk-16.04 使用 epoll 来监控中断事件，注册中断时，pci 网卡绑定到 igb_uio 生成的 uio 文件的句柄会被添加到 epoll 事件中，注册完成后通过 epoll_wait 来监控是否有中断触发。
### 3. 支持中断事件动态注册与销毁
dpdk-16.04 创建了一个 pipe 用于重新构建中断监听事件。pipe 的 read 端也被添加到 epoll 事件中，在注册中断完成后会向 pipe 的 write 端写入数据，中断处理线程监控到 pipe read 端有数据，则重新构建中断事件。
	同样当在销毁一个中断事件的最后也会向 pipe 的 write 端写入数据，通知中断处理线程，重新构建事件监听列表。
	