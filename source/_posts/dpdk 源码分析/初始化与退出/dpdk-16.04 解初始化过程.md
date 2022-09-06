# dpdk-16.04 解初始化过程
## dpdk-16.04 程序解初始化过程
dpdk-16.04 解初始化过程相对简单，这里以 l2fwd 程序的退出过程来分析。

## l2fwd 程序退出过程

l2fwd 程序正常退出代码如下：

```c
	for (portid = 0; portid < nb_ports; portid++) {
		if ((l2fwd_enabled_port_mask & (1 << portid)) == 0)
			continue;
		printf("Closing port %d...", portid);
		rte_eth_dev_stop(portid);
		rte_eth_dev_close(portid);
		printf(" Done\n");
	}
```

上述逻辑对每个已经使能的接口依次执行如下操作：

1. stop 接口
2. close 接口

l2fwd 程序在收发包线程的循环中不断判断 force_quit 变量的值，当此值不为 0 时，收发包线程主动终止，主线程中检测到收发包线程终止后，释放 dpdk 占用的接口。

rte_eth_dev_stop 与 rte_eth_dev_close 是对网卡底层 dev_ops 调用的封装层，这里我以 igb 网卡为例说明下其中的一些细节。

## igb 网卡实例化的 dev_stop 函数

igb 网卡驱动实例化的 dev_stop 函数为 eth_igb_stop，此函数的主要逻辑如下：

1. 调用 igb_intr_disable 写寄存器使能每个中断的掩码，关闭硬件中断
2. 调用 rte_intr_disable 同步关闭内核态网卡接口中断，对于使用 uio 与 igb_uio 这种方式来说，它会向 /dev/uioX 文件中写入 0 来调用 igb_uio 中的 igbuio_pci_irqcontrol 函数
3. 调用 igb_pf_reset_hw reset 网卡接口，将硬件状态还原到初始状态
4. 关闭 phy 的电源
5. 释放每个 tx_queue、rx_queue 上 sw_ring 占用的 mbuf，并将队列与描述符重新初始化
6. 修改 link 接口体，将 link 软件状态设置为 0，表示接口 down
7. 移除当前接口上设定的所有 flex_filter、ntuple_filter 配置
8. 重新注册默认的中断处理函数
9. 从中断线程的 epoll 列表中移除当前接口使用的 /dev/uioX 文件描述符

10. 释放中断向量号数组



## igb 网卡实例化的 dev_close 函数

igb 网卡驱动实例化的 dev_close 函数为 eth_igb_close，此函数的主要逻辑如下：

1. 调用 eth_igb_stop stop 接口
2. reset phy 并执行其它相关的硬件 reset 操作
3. 释放每个 rx_queue、tx_queue 上申请的动态内存，如所有的 rx_desc 与 tx_desc，所有的 sw_ring 及 rx_queue、tx_queue 结构体
4. 释放中断向量数组
5. 修改 link 接口体，将 link 软件状态设置为 0，表示接口 down

写到这里我发现 eth_igb_close 中调用了 eth_igb_stop，那为啥还需要调用 rte_eth_dev_stop 呢？

首先把 rte_eth_dev_stop 函数的代码贴到下面：

```c
void
rte_eth_dev_stop(uint8_t port_id)
{
    struct rte_eth_dev *dev;

    RTE_ETH_VALID_PORTID_OR_RET(port_id);
    dev = &rte_eth_devices[port_id];

    RTE_FUNC_PTR_OR_RET(*dev->dev_ops->dev_stop);

    if (dev->data->dev_started == 0) {
        RTE_PMD_DEBUG_TRACE("Device with port_id=%" PRIu8
            " already stopped\n",
            port_id);
        return;
    }

    dev->data->dev_started = 0;
    (*dev->dev_ops->dev_stop)(dev);
}

```

能够看到 rte_eth_dev_stop 除了调用底层网卡驱动实现的 dev_stop 之外，还要设定 dev->data->dev_started 变量的值，该值是 dpdk 内部变量，独立于每个物理网卡，这就是要在 rte_eth_dev_close 函数调用前调用一次 rte_eth_dev_stop 的原因。

## rte_eth_dev_close 函数

dev->data 中的 rx_queues、tx_queues 中保存网卡每个收发队列的地址，是 dpdk 在初始化接口的时候申请的，此结构是驱动独立的，因此由 dev_ops 的封装层来释放，释放逻辑在 rte_eth_dev_close 中，代码如下:

```c
void
rte_eth_dev_close(uint8_t port_id)
{
	struct rte_eth_dev *dev;

	RTE_ETH_VALID_PORTID_OR_RET(port_id);
	dev = &rte_eth_devices[port_id];

	RTE_FUNC_PTR_OR_RET(*dev->dev_ops->dev_close);
	dev->data->dev_started = 0;
	(*dev->dev_ops->dev_close)(dev);

	rte_free(dev->data->rx_queues);
	dev->data->rx_queues = NULL;
	rte_free(dev->data->tx_queues);
	dev->data->tx_queues = NULL;
}
```

这里释放了如下两个项目的资源：

1. rx_queues （存放每个 rx_queue 的地址）

2. tx_queues (存放每个 tx_queue 的地址)

## dev->data->dev_private 结构的释放

dpdk 的 pmd pci 驱动存在一些内部的数据结构，这部分数据结构的大小在注册驱动的时候通过 eth_driver 中的 dev_private_size 字段来设定，dpdk probe 接口的时候会申请相应大小的数据结构，驱动内部通过访问 dev->data->dev_private 来使用这些结构。

igb 网卡的 eth_driver 内容如下：

```c
static struct eth_driver rte_igb_pmd = {
	.pci_drv = {
		.name = "rte_igb_pmd",
		.id_table = pci_id_igb_map,
		.drv_flags = RTE_PCI_DRV_NEED_MAPPING | RTE_PCI_DRV_INTR_LSC |
			RTE_PCI_DRV_DETACHABLE,
	},
	.eth_dev_init = eth_igb_dev_init,
	.eth_dev_uninit = eth_igb_dev_uninit,
	.dev_private_size = sizeof(struct e1000_adapter),
};
```

igb 网卡声明了需要创建 e1000_adapter 这个结构体大小的私有空间，此空间只在底层驱动中使用。**那这个空间在哪里被释放呢？**

上文中描述的 l2fwd 的退出逻辑并不会释放 dev_private 接口，通过阅读代码发现，这一结构只有当程序调用了 rte_eth_dev_detach 函数的时候才会被释放，故而这部分逻辑不在 dpdk 程序的解初始化过程中，它实际上是**由内核回收**的。

## pci 设备的 unmap 

与 dev_private 结构类似的还有 pci 设备资源的 unmap 过程，此过程也只在 rte_eth_dev_detach 函数被调用的时候才会执行，也是由内核回收的。

## dpdk 程序异常终止时资源会释放吗？

上文中我们描述的一些动态空间的释放过程是程序正常退出时才会执行的，当程序异常终止，如收到 SIGKILL 信号被内核强制杀死时，这部分逻辑不会被执行，那么如何确保这些资源被释放呢？

实际上这些资源是由内核回收的，这才保证了程序异常终止时不至于出现资源泄露！

kni 程序由于会在内核中创建一些数据结构，它的资源回收需要额外处理，这部分工作是在 rte_kni 模块中完成的。**当 kni 程序异常终止时，内核会回收进程的描述符，调用相应的 close 函数，对 /dev/kni 文件来说它就是 kni_release 函数，此函数负责释放内核中创建的动态接口如 netdev 等资源**



kni 程序正常终止时会调用 ioctl 并传递 RTE_KNI_IOCTL_RELEASE 参数，rte_kni 模块中会调用 kni_ioctl_release 

来释放资源，阅读代码就可以**发现 kni_ioctl_release 执行的过程是 kni_release 函数的一个子集**，毕竟当程序异常终止时 ioctl 不会被调用，内核也无法协助处理，这时内核回收 /dev/kni 文件对应的描述符时调用 kni_release 就能够回收所有资源，避免出现部分资源的泄露问题！