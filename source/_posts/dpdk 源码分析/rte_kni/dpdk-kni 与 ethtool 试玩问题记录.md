# dpdk-kni与ethtool试玩问题记录
ethtool  能够 dump 网卡的寄存器，查看其它网卡相关的信息。在 dpdk 程序出现异常时，常常需要使用 ethtool 获取网卡的一些信息来定位问题。

我最近也尝试用了用 ethtool，中间却遇到了很多问题。**我使用的 dpdk 版本是 17.05。**

**第一类是编译相关的问题，第二类是 ethtool 自身支持网卡的问题。下面我就从这两方面的问题开始描述。**

## 使用 ethtool 时的 .config 配置
dpdk 的官方文档中说明，要使用 ethtool 需要使能 KNI_KMOD_ETHTOOL 功能项。这通过修改 .config 配置文件来完成。修改完成之后重新编译即可，这个问题相对简单。

执行了 kni 程序之后，通过 ifconfig 可以看到多出了一个网卡，这个网卡就是之后我使用 ethtool 来查看的网卡硬件。

## hugepage 内存不足导致 eal 初始化失败的问题
执行 ifconfig 命令看到多出来的网卡之后，我以为 ethtool 就能正常工作，结果它在启动的时候就报了错，错误信息表明 eal 初始化失败。

具体的报错信息表明没有足够的 hugepage 内存使用。

我猜是因为 kni 程序将所有的 hugepage 内存全部独占造成了这个问题，就修改了 /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 文件，这之后 eal 初始化这一步没有报错，但是又出现了一个新的错误，错误内容如下：

> Cannot create lock on '/var/run/.rte_config'. Is another primary process running?

在网上搜索了下这个问题，没有发现什么解决方案。

## ethtool 不支持当前网卡
删除 /var/run/.rte_config 后重新运行 kni 程序，执行 ethtool 命令后，dmesg 查看系统信息发现了如下内容：

> Device not supported by ethtool

这个信息表面上看来是说 ethtool 不支持我的网卡，但是我使用的是 e1000 的网卡呀，我想应该不至于不支持吧。

为了确认 ethtool 是否支持我的网卡，我使用 cscope 在源码中搜索 Device not supported by ethtool 这个字符串，发现它是在 kni_misc.c 中的 kni_ioctl_create 函数中打印的。这个函数中会用获取到的当前网卡信息查询两张表——ixgbe_pci_tbl 与 igb_pci_tbl。

这两张表的部分内容摘录如下：

```c
const struct pci_device_id ixgbe_pci_tbl[] = {
	{PCI_VDEVICE(INTEL, IXGBE_DEV_ID_82598)},
	{PCI_VDEVICE(INTEL, IXGBE_DEV_ID_82598AF_DUAL_PORT)},
	{PCI_VDEVICE(INTEL, IXGBE_DEV_ID_82598AF_SINGLE_PORT)},
	{PCI_VDEVICE(INTEL, IXGBE_DEV_ID_82598AT)},
	...........................................
	/* required last entry */
	{0, }
};

const struct pci_device_id igb_pci_tbl[] = {
	{ PCI_VDEVICE(INTEL, E1000_DEV_ID_I354_BACKPLANE_1GBPS) },
	{ PCI_VDEVICE(INTEL, E1000_DEV_ID_I354_SGMII) },
	{ PCI_VDEVICE(INTEL, E1000_DEV_ID_I354_BACKPLANE_2_5GBPS) },
	..........................................................
	/* required last entry */
	{0, }
};

```
我使用 lspci 命令查看我的网卡型号，得到的信息如下：

>e1000 82545EM

这个型号在 dpdk 中对应的宏是 E1000_DEV_82545EM，并不存在于上面的两张表中，这表明 ethtool 确实不支持此款网卡。从第二张表中我发现 e1000 网卡是一个系列，其中有很多不同型号的网卡，这是我之前没有意识到的问题。

其实这是 dpdk 的 rte_kni 模块不支持这个网卡，官方驱动是支持的。
