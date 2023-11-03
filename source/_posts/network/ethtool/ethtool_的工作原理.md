# ethtool 的工作原理
## ethtool 是如何工作的？
源码之前，了无秘密。要知道 ethtool 是如何工作的，我们需要获取到它的源码。

### 如何获取 ethtool 的源码?
这可以通过在网络上搜索来完成，但是我这里有一个非常简单的方法。由于我使用的是 debian 系统，我执行如下命令获取 ethtool 工具的源码：

```bash
longyu@longyu-pc:~$ sudo apt-get source ethtool
```
执行完上述命令之后，查看当前目录，ethtool 的源码包已经下载了下来。在我的系统中相关的文件如
下：

>ethtool_4.19-1.debian.tar.xz
> ethtool_4.19.orig.tar.xz

我将这两个文件解压，发现 ethtool 的源码在 ethtool_4.19.orig.tar.xz 中。

### ethtool 的工作流程
通过阅读源码，我大致理清了 ethtool 工具的工作流程。

**ethtool 的核心在于通过 ioctl 的 SIOCETHTOOL 命令来调用网络设备驱动中实现的 ethtool 方法的实例来获取数据，然后根据不同网卡的不同配置格式化数据以输出。**

ethtool 命令使用 send_ioctl 函数来从网卡中获取信息。send_ioctl 函数的源码如下：

```c
int send_ioctl(struct cmd_context *ctx, void *cmd)
{
	ctx->ifr.ifr_data = cmd;
	return ioctl(ctx->fd, SIOCETHTOOL, &ctx->ifr);
}
```

这里的 ctx 参数可以看做是 ioctl 执行的环境，其中需要注意的是两个字段：

**1. ctx->fd**
	ctx->fd 是在 main 函数中通过调用 socket 函数来获取到的网络设备的文件描述符。相关代码如下：


```c
		ctx.fd = socket(AF_INET, SOCK_DGRAM, 0);
		if (ctx.fd < 0)
			ctx.fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
		if (ctx.fd < 0) {
			perror("Cannot get control socket");
			return 70;
		}
```
**2. ctx->ifr 结构体**

ifr 结构体中重要的是两个字段：

1. ifr_name 
    
   ifr_name 中保存的内容是我们在命令行中指定的网络设备的名称，如 eth1、ens33 等。
    
2. ifr_data 

   ifr_data 中保存着 ethtool 中更为具体的命令，如 ETHTOOL_GDRVINFO、ETHTOOL_GREGS、ETHTOOL_GWOL 等。


ctx->fd 这个文件描述符是网络设备的文件描述符，在内核中对应了网络设备的私有 file_operations。这个 file_operations 虚函数表在 socket.c 中被定义。

## ioctl 函数中的控制传递
ethtool 命令执行 ioctl 后进入内核，在内核中控制传递的过程如下：

>sock_ioctl ---> dev_ioctl ---> dev_ethtool ---> ethtool layer --->dev->ethtool_ops

最终调用到的函数是在网卡驱动初始化过程中调用 SET_ETHTOOL_OPS 设定的【ethtool_ops】虚函数表中的函数指针。在 netdev 结构体中有指向 ethtool_ops 虚函数表的指针，不同的网卡将绑定不同的虚函数表，这实现了 ethtool【接口的重载】。

既然不同的网卡会绑定不同的虚函数表，那么我们是怎样通过网卡接口名称获取到这张表的呢？

我想这一定与 ethtool 命令在执行时传递的 devname 有关。既然在 netdev 结构体中有指向 ehtool_ops 虚函数表的指针，那么问题就变成了 devname 表示的网络接口 netdev 结构如何获取到的问题。
## devname 对应的网络接口的 netdev 结构是如何获取到的？
详细的描述请参考我的这篇博文——[ethtool 命令指定的 devname 是在哪里被使用的？](https://blog.csdn.net/Longyu_wlz/article/details/103249749)

## 总结
ethtool 的工作原理非常简单，但是在内核中的调用层次非常复杂。我这里只对 ethtool 的工作原理进行了非常粗糙的描述，忽略了一些细节。理清 ethtool 的工作原理之后，我发现其实只需要关注网卡驱动中的 ethtool_ops 虚函数表的实现以及在 ethtool 调用时传递的 devname 在哪里被使用这两个方面就能够抓住关键。

