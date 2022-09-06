# dpdk 用户态驱动框架及其演进过程分析
dpdk 用户态驱动框架是 dpdk 相对核心的功能，本文将从老版本驱动框架开始描述，从演进过程中一步步逼近高版本中相对完善的驱动框架的设计原理。
## dpdk v1.2.3 r0 版本
dpdk git 中最老的版本为 v1.2.3 r0 版本，此版本中用户态驱动框架实现的关键环节如下：

1. igb_uio 中完成将中断映射到用户态的任务，并填充 uio 结构体中 pci 资源空间的地址与长度，它注册的 pci_driver 中， id_table 字段不为空，其值如下：

	```c
	static struct pci_device_id igbuio_pci_ids[] = {
	#define RTE_PCI_DEV_ID_DECL(vend, dev) {PCI_DEVICE(vend, dev)},
	#include <rte_pci_dev_ids.h>
	{ 0, },
	};
	```
2. rte_eal_init 函数中完成扫描 pci 设备的过程，扫描到的 pci 设备会填充到 device_list 链表中，rte_eal_init 函数中并不进行驱动 probe 过程，因为此时还未注册任何一个驱动。
3. 这个版本的 dpdk 只支持 igb 与 ixgbe 两个系列的用户态驱动，每个驱动会实现一个注册函数并将注册函数暴露给 dpdk 程序使用，显式完成驱动注册过程。
4. 由于驱动注册是在 dpdk 程序中完成的，驱动 probe pci 设备的过程也是在 dpdk 程序中显式调用 probe 函数完成的。
5. rte_eal_pci_probe 函数遍历在 rte_eal_init 中创建的 device_list pci 设备链表，使用这个链表中的每个 pci 设备去 match 注册的 pci 驱动链表。
6. 当一个 pci 设备 match 到一个驱动后，首先调用 pci_uio_map_resource 函数来通过 map /dev/uioX 文件来映射 pci 的 resource 资源并填充到 pci 设备结构体中，然后调用 pci 驱动中的 devinit 函数完成接口初始化过程。
7. pci 驱动中并不定义 devinit 函数，它在显示注册驱动时，通过调用 rte_eth_driver_register 函数来设定，其值被设定为 rte_eth_dev_init 函数。
8. 第 ６点中描述的 pci 驱动中的 devinit 函数就是第 7 点中的 rte_eth_dev_init 函数，rte_eth_dev_init 函数实现 pci 设备结构体与 dpdk 内部 rte_eth_dev 设备结构体的对接过程。
9. 在 pci 这一侧每一个设备由一个 rte_pci_device 结构描述。由于 dpdk 需要对外提供网卡控制接口，这些控制过程中的参数是与驱动无关的，不能通过直接操作 pci 这一层的数据结构来完成，为此 dpdk 在此基础上进行了抽象，抽象出了 rte_eth_dev 设备结构体。
10. 每一个 dpdk 初始化的 pci 接口都会分配一个唯一的 rte_eth_dev 结构体，dpdk 内部维护了一个 rte_eth_devices 全局变量，它是一个 rte_eth_dev 结构体数组，每个接口都从这个数组中分配一个 rte_eth_dev 结构体，外部接口通过指定一个 port_id 来让 rte_ethdev 这一层获取到 rte_eth_dev 结构，调用底层的函数来完成功能。

### 从 l2fwd 示例程序代码处探究
如下源码摘自此版本的 l2fwd 示例程序：

```c
	        /* init EAL */
	        ret = rte_eal_init(argc, argv);
	..........................................
	#ifdef RTE_LIBRTE_IGB_PMD
	        if (rte_igb_pmd_init() < 0)
	                rte_exit(EXIT_FAILURE, "Cannot init igb pmd\n");
	#endif
	#ifdef RTE_LIBRTE_IXGBE_PMD
	        if (rte_ixgbe_pmd_init() < 0)
	                rte_exit(EXIT_FAILURE, "Cannot init ixgbe pmd\n");
	#endif
	
	        if (rte_eal_pci_probe() < 0)
	                rte_exit(EXIT_FAILURE, "Cannot probe PCI\n");
```
可以看到，igb 网卡与 ixgbe 网卡驱动调用驱动提供的初始化函数来显示注册，注册完成后，调用 rte_eal_pci_probe 来完成 probe 过程。

### eth_driver 结构
**此版本仅支持 pci 驱动**，每个驱动需要实例化一个 eth_driver 结构，此结构的定义如下：

```c
	struct eth_driver {
		struct rte_pci_driver pci_drv;    /**< The PMD is also a PCI driver. */
		eth_dev_init_t eth_dev_init;      /**< Device init function. */
		unsigned int dev_private_size;    /**< Size of device private data. */
	};
```
pci_drv 是对用户态 pci 设备驱动的抽象，eth_dev_init 用户态驱动的初始化函数，dev_private_size 是每个设备的私有数据大小。

每个驱动都要实例化一个 eth_driver 结构体，并显示的调用注册函数进行注册。igb 网卡的 eth_driver 结构体实例如下：

```c
static struct eth_driver rte_igb_pmd = {
	{
		.name = "rte_igb_pmd",
		.id_table = pci_id_igb_map,
		.drv_flags = RTE_PCI_DRV_NEED_IGB_UIO,
	},
	.eth_dev_init = eth_igb_dev_init,
	.dev_private_size = sizeof(struct e1000_adapter),
};
```

**由于 eth_driver 结构体的第一个元素为 rte_pci_driver 结构，可以很容易的将一个 eth_driver 结构地址转化为一个 rte_pci_driver 结构地址（通过强转）**。

### rte_pci_driver 结构
rte_pci_driver 结构是对 pci 驱动的抽象，其定义如下：

```c
/**
 * A structure describing a PCI driver.
 */
struct rte_pci_driver {
	TAILQ_ENTRY(rte_pci_driver) next;       /**< Next in list. */
	const char *name;                       /**< Driver name. */
	pci_devinit_t *devinit;                 /**< Device init. function. */
	struct rte_pci_id *id_table;            /**< ID table, NULL terminated. */
	uint32_t drv_flags;                     /**< Flags contolling handling of device. */
};
```
rte_pci_driver 的 next 字段用于将注册的 pci 驱动串联起来，devinit 函数用于设备初始化。

### rte_pci_driver 结构体中的 devinit 函数
igb 驱动实现的 rte_pci_driver 结构中并没有设定 devinit 字段，这个字段在 dpdk 程序显式调用 rte_igb_pmd_init 注册 igb 驱动的时候被赋值。

rte_igb_pmd_init 函数代码如下：
```c
int
rte_igb_pmd_init(void)
{
	rte_eth_driver_register(&rte_igb_pmd);
	return 0;
}
```
rte_eth_driver_register 函数代码如下：

```c
void
rte_eth_driver_register(struct eth_driver *eth_drv)
{
	eth_drv->pci_drv.devinit = rte_eth_dev_init;
	rte_eal_pci_register(&eth_drv->pci_drv);
}
```
如上代码能够说明 rte_pci_driver 中的 devinit 函数在驱动显示注册时被赋值为 rte_eth_dev_init 函数，那么 **eth_driver 中注册的 eth_dev_init 函数在哪里被调用呢？**

### rte_eth_dev_init 函数
eth_driver 结构体中注册的 eth_dev_init 函数在 rte_eth_dev_init 函数中被调用，rte_eth_dev_init 函数的代码如下：

```c
static int
rte_eth_dev_init(struct rte_pci_driver *pci_drv,
		 struct rte_pci_device *pci_dev)
{
	struct eth_driver    *eth_drv;
	struct rte_eth_dev *eth_dev;
	int diag;

	eth_drv = (struct eth_driver *)pci_drv;

	eth_dev = rte_eth_dev_allocate();
	if (eth_dev == NULL)
		return -ENOMEM;


	if (rte_eal_process_type() == RTE_PROC_PRIMARY){
		eth_dev->data->dev_private = rte_zmalloc("ethdev private structure",
				  eth_drv->dev_private_size,
				  CACHE_LINE_SIZE);
		if (eth_dev->data->dev_private == NULL)
			return -ENOMEM;
	}
	eth_dev->pci_dev = pci_dev;
	eth_dev->driver = eth_drv;
	eth_dev->data->rx_mbuf_alloc_failed = 0;

	/* init user callbacks */
	TAILQ_INIT(&(eth_dev->callbacks));

	/*
	 * Set the default maximum frame size.
	 */
	eth_dev->data->max_frame_size = ETHER_MAX_LEN;

	/* Invoke PMD device initialization function */
	diag = (*eth_drv->eth_dev_init)(eth_drv, eth_dev);
	if (diag == 0)
		return (0);

	PMD_DEBUG_TRACE("driver %s: eth_dev_init(vendor_id=0x%u device_id=0x%x)"
			" failed\n", pci_drv->name,
			(unsigned) pci_dev->id.vendor_id,
			(unsigned) pci_dev->id.device_id);
	if (rte_eal_process_type() == RTE_PROC_PRIMARY)
		rte_free(eth_dev->data->dev_private);
	nb_ports--;
	return diag;
}
```
此函数中首先为当前的 pci 设备分配一个 rte_eth_dev 结构，然后使用 eth_drv 结构体中定义的 dev_private_size 字段来创建驱动内部数据结构。

此后，继续初始化 rte_eth_dev 结构体中的字段，最后调用 eth_driver 结构体中的 eth_dev_init 函数指针指向的函数，完成接口底层初始化过程。

### 以一个 igb 网卡接口来串起 dpdk v1.2.3 r0 版本接口初始化的整个过程
假定某 linux 系统中有一个 igb 网卡，它只有两个口，这两个口的 pci 号分别为 0000:01:00.0、0000:01:00.1，0000:01:00.0 这个口由内核驱动接管，0000:01:00.1 这个口用于 dpdk 转包（确认 igb_uio 网卡支持此网卡）。

假定 igb_uio 驱动正常加载，大页内存正常配置，分析模型基于 primary 进程。

下面是具体过程：

1. 将 0000:01:00.1 从 igb 驱动解绑
2. 将 0000:01:00.1 写入到 /sys 目录中 igb_uio 的 bind 文件中，绑定接口到 igb_uio，绑定后 /dev/uio0 文件被创建，/sys 目录中相应的文件被创建，uio map 地址相关文件被创建，示例内容如下：

	```bash
	 [root] # pwd
	/sys/bus/pci/drivers/igb_uio/0000:01:00.0
	 [root] # cat ./uio/uio0/maps/map0/addr ./uio/uio0/maps/map0/name  ./uio/uio0/maps/map0/size ./uio/uio0/maps/map0/offset
	0xfebf3000
	BAR1
	0x1000
	0x0
	```
3. dpdk 程序调用 rte_eal_init 初始化，扫描 /sys/bus/pci/devices 目录，解析子目录 0000:01:00.1 中的文件，填充到一个新创建的 rte_pci_device 结构体中，填充完成后将此结构体链入到 device_list 设备链表中。0000:01:00.1 目录中的重要文件含义见下表：

	| file               | function                                              |
	| ------------------ | ----------------------------------------------------- |
	| class              | PCI class (ascii, ro)                                 |
	| config             | PCI config space (binary, rw)                         |
	| device             | PCI device (ascii, ro)                                |
	| enable             | Whether the device is enabled (ascii, rw)             |
	| irq                | IRQ number (ascii, ro)                                |
	| local_cpus         | nearby CPU mask (cpumask, ro)                         |
	| remove             | remove device from kernel's list (ascii, wo)          |
	| resource           | PCI resource host addresses (ascii, ro)               |
	| resource0..N       | PCI resource N, if present (binary, mmap, rw[1])      |
	| resource0_wc..N_wc | PCI WC map resource N, if prefetchable (binary, mmap) |
	| rom                | PCI ROM resource, if present (binary, ro)             |
	| subsystem_device   | PCI subsystem device (ascii, ro)                      |
	| subsystem_vendor   | PCI subsystem vendor (ascii, ro)                      |
	| vendor             | PCI vendor (ascii, ro)                                |

4. dpdk 程序执行 rte_igb_pmd_init 注册 igb 驱动，rte_igb_pmd 结构体中 pci_drv 结构的 devinit 函数指针被设置为 rte_eth_dev_init 函数。
5. dpdk 程序调用 rte_eal_pci_probe 函数完成驱动 probe 过程，rte_eal_pci_probe 函数依次遍历 device_list 链表，获取到 0000:01:00.1 接口填充的 rte_pci_device 结构体，然后调用 pci_probe_all_drivers 函数完成驱动 probe 过程。
6. pci_probe_all_drivers 函数遍历 driver_list 链表，首先判断当前设备是否被加入到黑名单，是则跳过此设备，这里由于程序执行时没有配置黑名单，不会走入这个逻辑。
7. pci_probe_all_drivers 函数获取到注册的 igb 驱动的 rte_pci_driver 结构，使用此结构与 rte_pci_device 结构为参数调用 rte_eal_pci_probe_one_driver 函数
8. rte_eal_pci_probe_one_driver 函数使用 rte_pci_device 结构体中保存的设备的 vendor id 与 device id 在 pci_id_igb_map 列表中进行匹配，成功匹配后调用 pci_uio_map_resource 来 mmap pci resource 地址到用户态中。
9. pci_uio_map_resource 首先找到并解析 /sys/bus/pci/drivers/igb_uio/0000:01:00.0/uio/uio0/maps/map0/ 下的 offset 与 size 文件，获取 pci resource 的偏移与大小，解析到 offset 为 0x0，size 为 0x1000，打开 /dev/uio0 文件，通过 mmap 映射 pci resource 到用户态中。
10. mmap 成功后得到的虚拟地址填充到 rte_pci_device 中的 mem_resource.addr 中，然后创建一个 uio_res 结构，保存映射后的虚拟地址与 offset、size，并填充 path 与 pci_addr 唯一标识到 uio_res 结构，最后将此结构链入到 uio_res_list 链表中。
11. 再次回到 rte_eal_pci_probe_one_driver 中，调用 pci_drv 中的 devinit 函数，即 rte_eth_dev_init 函数。
12. rte_eth_dev_init 函数填充当前接口的 rte_eth_dev 结构体后调用 eth_igb_dev_init 函数。
13. eth_igb_dev_init 函数继续初始化 rte_eth_dev 结构中与驱动相关的重要数据结构，将 rte_eth_dev_init 函数中创建的驱动内部数据结构地址 eth_dev->data->dev_private 转化为 e1000_adapter 结构，并获取 e1000_adpater 结构体中 e1000_hw 的地址，完成后将第 10 步中 mmap 到的 pci resource 地址赋值给 hw->hw_addr 结构，此后读写网卡寄存器都是以这个 hw_addr 为基地址完成的。
14. eth_igb_dev_init 完成硬件初始化过程并注册中断回调函数。
15. dpdk 程序继续调用 rte_ethdev.c 中实现的网卡控制接口，配置网卡的收发队列并将接口 up 起来
16. dpdk 程序完成接口的配置后，派发自己实现的 loop 函数到每个使能的 lcore 线程上，执行收发包过程。

### 总结 v1.2.3 r0 版本用户态驱动框架关键知识与隐含问题
1. v1.2.3 r0 版本通过 mmap /dev/uio 文件来映射 pci resource 资源
2. v1.2.3 r0 版本需要显式调用每个驱动的注册函数，扩展性较差，这种架构下每添加一个新类别的驱动，dpdk 程序需要修改源码后重新编译
3. rte_eth_driver、rte_pci_driver 中只有初始化函数，没有解初始化函数，缺少主动释放资源的过程
4. 此版本仅支持 pci 驱动，没有抽象出 bus 层，bus 层功能零散分布在扫描 pci 设备与 probe 设备过程中，不太合理
5. 缺少 ethtool、ifconfig 等 linux 中传统网络接口控制命令的替代工具

以上几个问题在后续版本中渐渐完善，下面我将对后续版本中的一些关键修改进行描述。

## dpdk v1.4.0r0 版本
此版本解决了显式调用每个驱动注册函数的问题，向外界提供了 rte_pmd_init_all 接口，适配新的驱动时，不需要修改上层程序的代码，只需要重新链接新的 dpdk 即可。

rte_pmd_init_all 函数代码如下：

```c
static inline
int rte_pmd_init_all(void)
{
	int ret = -ENODEV;

#ifdef RTE_LIBRTE_IGB_PMD
	if ((ret = rte_igb_pmd_init()) != 0) {
		RTE_LOG(ERR, PMD, "Cannot init igb PMD\n");
		return (ret);
	}
	if ((ret = rte_igbvf_pmd_init()) != 0) {
		RTE_LOG(ERR, PMD, "Cannot init igbvf PMD\n");
		return (ret);
	}
#endif /* RTE_LIBRTE_IGB_PMD */

#ifdef RTE_LIBRTE_EM_PMD
	if ((ret = rte_em_pmd_init()) != 0) {
		RTE_LOG(ERR, PMD, "Cannot init em PMD\n");
		return (ret);
	}
#endif /* RTE_LIBRTE_EM_PMD */

#ifdef RTE_LIBRTE_IXGBE_PMD
	if ((ret = rte_ixgbe_pmd_init()) != 0) {
		RTE_LOG(ERR, PMD, "Cannot init ixgbe PMD\n");
		return (ret);
	}
	if ((ret = rte_ixgbevf_pmd_init()) != 0) {
		RTE_LOG(ERR, PMD, "Cannot init ixgbevf PMD\n");
		return (ret);
	}
#endif /* RTE_LIBRTE_IXGBE_PMD */

	if (ret == -ENODEV)
		RTE_LOG(ERR, PMD, "No PMD(s) are configured\n");
	return (ret);
}
```
这个版本增加了对 e1000 与 igb vf、ixgbe vf 驱动的支持，pci resource 地址仍旧通过 mmap /dev/uioX 文件来完成。

## dpdk v1.5.0r0 版本
此版本增加了更多的 pmd 驱动，增加了对诸如 pcap 等非 pci 网卡驱动的支持。非 pci 网卡驱动有单独的初始化函数 rte_eal_non_pci_ethdev_init，此函数在 rte_eal_init 函数中被调用。

其源码如下：
```c
int
rte_eal_non_pci_ethdev_init(void)
{
	uint8_t i, j;
	for (i = 0; i < NUM_DEV_TYPES; i++) {
		for (j = 0; j < RTE_MAX_ETHPORTS; j++) {
			const char *params;
			char buf[16];
			rte_snprintf(buf, sizeof(buf), "%s%"PRIu8,
					dev_types[i].dev_prefix, j);
			if (eal_dev_is_whitelisted(buf, &params))
				dev_types[i].init_fn(buf, params);
		}
	}
	return 0;
}
```
可以看到它实际是通过遍历 dev_types 这个数组来初始化的，其它的参数通过命令行获取。

dev_types 数组代码如下：

```c
struct device_init dev_types[] = {
#ifdef RTE_LIBRTE_PMD_RING
		{
			.dev_prefix = RTE_ETH_RING_PARAM_NAME,
			.init_fn = rte_pmd_ring_init
		},
#endif
#ifdef RTE_LIBRTE_PMD_PCAP
		{
			.dev_prefix = RTE_ETH_PCAP_PARAM_NAME,
			.init_fn = rte_pmd_pcap_init
		},
#endif
		{
			.dev_prefix = "-nodev-",
			.init_fn = NULL
		}
};
```
dev_prefix 用于标识 vdev 驱动，init_fn 是驱动的初始化函数。这样的实现存在的问题是 vdev 与 pci 等物理网卡驱动的注册与初始化过程没有统一，需要一个新的抽象层次来解决这个问题。

同时，这个版本引入了 kni 模块，当使用了 kni 模块后，支持通过 ethtool、ifconfig 这些标准命令控制网卡接口，弥补了现有工具的不足，同时也打通了 dpdk 程序与内核协议栈的交互过程。

kni 支持 ethtool 获取数据实质上是维护了一套内核态的驱动，同时为了避免与用户态同时使用造成问题，对内核驱动进行了一系列定制化修改，带来新功能的同时也引入了新的问题。

## dpdk v1.7.0
v1.7.0 对用户态驱动架构进行了较大幅度的调整，抽象出了一个 rte_driver 结构来屏蔽 vdev 与 pdev 的差别，统一了注册过程。

同时也剔除了显式调用驱动注册函数的实现，改为通过 gcc 的 constructor 属性在 main 函数执行前自动注册，同时 probe 的逻辑也合并到了 rte_eal_init 函数中调用，上层程序对底层驱动的注册与 probe 过程完全不感知。

### rte_driver 结构
rte_driver 结构的定义如下：
```c
struct rte_driver {
	TAILQ_ENTRY(rte_driver) next;  /**< Next in list. */
	enum pmd_type type;		   /**< PMD Driver type */
	const char *name;                   /**< Driver name. */
	rte_dev_init_t *init;              /**< Device init. function. */
};
```
next 字段将不同的 rte_driver 链起来，type 字段用于区分 PMD 驱动的类型，如 PDEV、VDEV、BDEV，init 函数是对老版本每个驱动的注册函数的抽象。

igb pmd 驱动实例化的结构如下：
```c
3061 static struct rte_driver pmd_igb_drv = {
3062     .type = PMD_PDEV,
3063     .init = rte_igb_pmd_init,
3064 };
```
设定 type 为 PMD_PDEV 表示这是一个物理网卡驱动，init 函数指向 rte_igb_pmd_init，rte_igb_pmd_init 本身完成自老版本继承的 eth_driver 驱动的注册，这里为了实现与 VDEV 驱动注册过程的统一，在每个 PDEV 驱动中使用 eth_driver 驱动的注册接口实例化一个 rte_driver 结构，将此结构在 main 函数之前注册到 dev_driver_list 链表中。

当 main 函数执行时，dev_driver_list 链表中保存了所有注册的 rte_driver 驱动，这些 rte_driver 驱动能够分为三个类别：
1. PDEV 标志的 pci 物理设备驱动实例化的 rte_driver
2. VDEV 标志的虚拟设备驱动实例化的 rte_driver
3. BDEV 标志 bond 虚拟设备驱动实例化的 rte_driver
### VDEV 类驱动
VDEV 类驱动的代表是 pcap 驱动，其 rte_driver 结构如下：

```c
static struct rte_driver pmd_pcap_drv = {
	.name = "eth_pcap",
	.type = PMD_VDEV,
	.init = rte_pmd_pcap_devinit,
};
```
type 为 PMD_VDEV 表示这是个虚拟网卡驱动，rte_pmd_pcap_devinit 函数实际上就是此驱动的初始化函数，并不需要再进行任何的注册过程。

### PDEV 类驱动
PDEV 类驱动的代表是 igb 驱动，这类驱动实例化的 rte_driver 结构中的 init 函数本身又是一个注册 eth_driver 驱动的函数，这就将原来 PDEV 类驱动的注册过程复杂化了，是统一接口带来的一些坏处。

这时候 PDEV 类驱动的注册过程可以总结为如下步骤：

1. 实例化 rte_driver 结构，并将 init 函数设定为 eth_driver 函数的注册函数
2. 通过 PMD_REGISTER_DRIVER 宏注册 rte_driver 结构，此结构在 main 函数执行前被注册到 dev_driver_list 链表中
3. rte_eal_init 中遍历 dev_driver_list 链表调用 PDEV 驱动中注册 eth_driver 结构的函数，完成与老版本相同的注册流程

PMD_REGISTER_DRIVER 宏的原理详见：[gcc constructor 属性修饰的构造函数未被链接问题](https://blog.csdn.net/Longyu_wlz/article/details/113725959?ops_request_misc=%257B%2522request%255Fid%2522%253A%2522161961368916780357248787%2522%252C%2522scm%2522%253A%252220140713.130102334.pc%255Fblog.%2522%257D&request_id=161961368916780357248787&biz_id=0&utm_medium=distribute.pc_search_result.none-task-blog-2~blog~first_rank_v2~rank_v29-1-113725959.pc_v2_rank_blog_default&utm_term=%E6%9E%84%E9%80%A0)

### BDEV 类驱动
1.7.0 中实现了 bond 虚拟接口驱动，bond 驱动完全是软件实现，但是最初的版本需要将 bond 驱动初始化过程放在 pci 设备 probe 之后来完成其功能，这种特殊的依赖关系催生了 BDEV 类驱动，不过这只是一个中间的过渡版本，后面的版本解决了这个问题，BDEV 与 VDEV 初始化过程得到了统一。

### rte_eal_dev_init 函数
1.7.0 版本实现了驱动的自动注册过程，这一过程可以分为两个阶段，第一个阶段是构造函数执行阶段，第二阶段是 pci 驱动的注册过程。

第二阶段的注册过程与驱动的 probe 过程都合并到了 rte_eal_init 函数中，上层程序完全不感知。

rte_eal_init 函数调用 rte_eal_dev_init 函数完成 VDEV 设备的初始化以及 pci 驱动的注册过程，由于 BOND 驱动的特殊性，rte_eal_dev_init 也被划分为了两个阶段。

PMD_INIT_PRE_PCI_PROBE 阶段初始化那些不依赖 pci 网卡的 VDEV 设备，这一阶段在 pci 设备 probe 之前执行，PMD_INIT_POST_PCI_PROBE 阶段仅用于 bond 设备初始化。

### igb_uio 中移除 pci id table
1.7.0 版本中 igb_uio 模块注册的 pci 驱动移除了 pci id table，此时绑定网卡到 igb_uio 需要先将网卡的 vendor id 与 device id 拼接得到的字符串写入到 igb_uio 在 /sys 子目录中的 new_id 文件中才能进行绑定。

### VFIO 模块的支持
v1.7.0 除了支持 igb_uio 这种标准的 uio 映射 pci 资源空间与中断到用户态外，也支持 vfio 模块。

我对 vfio 这块没有深入研究，不进一步描述了。

## v1.8.0
此版本解决了 bond 功能的限制，统一了所有 VDEV 的初始化过程。

## dpdk-16.04
dpdk-16.04 用户态驱动架构主体继续沿用 v1.8.0 版本代码，在统一 linux 平台与 bsd 平台 uio 函数的过程中，修改了 pci resource 的映射逻辑，不再通过 mmap /dev/uiox 文件来完成。

具体的原理可以阅读 [dpdk-16.04 igb_uio 模块分析](https://blog.csdn.net/Longyu_wlz/article/details/115956761?spm=1001.2014.3001.5501) 。

dpdk-16.04 中针对标准 viritio 驱动访问 io 端口的需求实现了 rte_eal_pci_ioport_map 等 ioport 相关的函数接口，当 virtio 网卡被绑定到 igb_uio 时，ioport 的基地址通过访问 /sys 目录中 virtio 设备子目录中 uio 子目录中的 port 接口来获取。

vtpci_init 函数中调用 legacy_virtio_resource_init 函数来 map virtio ioport，此过程实际上是通过调用 rte_eal_pci_ioport_map 函数完成的。

此函数源码如下：

```c
int
rte_eal_pci_ioport_map(struct rte_pci_device *dev, int bar,
		       struct rte_pci_ioport *p)
{
	int ret = -1;

	switch (dev->kdrv) {
#ifdef VFIO_PRESENT
	case RTE_KDRV_VFIO:
		if (pci_vfio_is_enabled())
			ret = pci_vfio_ioport_map(dev, bar, p);
		break;
#endif
	case RTE_KDRV_IGB_UIO:
		ret = pci_uio_ioport_map(dev, bar, p);
		break;
	case RTE_KDRV_UIO_GENERIC:
#if defined(RTE_ARCH_X86)
		ret = pci_ioport_map(dev, bar, p);
#else
		ret = pci_uio_ioport_map(dev, bar, p);
#endif
		break;
	case RTE_KDRV_NONE:
#if defined(RTE_ARCH_X86)
		ret = pci_ioport_map(dev, bar, p);
#endif
		break;
	default:
		break;
	}

	if (!ret)
		p->dev = dev;

	return ret;
}
```
当 virtio 绑定到 igb_uio 的时候调用 pci_uio_ioport_map 来获取 ioport 的基地址，pci_uio_ioport_map 通过访问并解析 /sys/bus/pci/devices/0000:xx:xx.x/uio/uioX/portio/portX/start 文件来完成，start 文件的值即为 portio 的基地址。

## dpdk 17.x bus 抽象层的引入
dpdk 17.x 版本最初合入了 nxp 公司的 fsl-mc bus driver，在此基础上，bus 抽象层不断完善，最终 pci、vdev bus 也得到了支持，用户态驱动架构的使用场景进一步拓宽，旧的架构被重构，新框架复杂性进一步增加。

目前还没有深入研究，未来单独写一篇博客描述新版本 bus 框架下用户态驱动的架构。

## 总结
本文从老版本 dpdk 着手，描述了在版本演进过程中 dpdk 用户态驱动架构的演变过程。

用户态驱动架构是 dpdk 非常核心的设计，对它的研究是我们与设计者对话的过程。从本文的分析中能够看出这一套框架并不是从一开始就这样复杂，就能够兼容多种场景并具备高度的可扩展性，这些元素是在程序的迭代中不断优化的。不同的架构有自己支持的特定场景，我们也应该以变化的角度来看待不同版本的优劣之处。

dpdk 的应用场景就是一种环境，环境的变化催化了程序内部架构的不断重构，我们不也在经历类似的过程吗？核心只是环境不同罢了！
