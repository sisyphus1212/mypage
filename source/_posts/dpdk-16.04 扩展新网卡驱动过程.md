---
title: dpdk-16.04 扩展新网卡驱动过程
date: 2022-09-03 12:30:56
index_img: https://www.dpdk.org/wp-content/uploads/sites/35/2021/03/DPDK_logo-01-1.svg
categories:
- [网络开发,数据包处理]
- dpdk
tags:
- dpdk
- 网络数据包
- 数据包
---

# 编译相关配置添加

## 1. 确定网卡的 vendor id 与 device id，在 rte_pci_dev_ids.h 中添加新的设备定义

示例信息如下：

```c
#ifndef RTE_PCI_DEV_ID_DECL_ICE
#define RTE_PCI_DEV_ID_DECL_ICE(vend, dev)
#endif

RTE_PCI_DEV_ID_DECL_ICE(PCI_VENDOR_ID_INTEL, ICE_DEV_ID_PF)
RTE_PCI_DEV_ID_DECL_ICE(PCI_VENDOR_ID_INTEL, ICE_DEV_ID_SDI_FM10420_QDA2)

#undef RTE_PCI_DEV_ID_DECL_ICE
```

## 2. 在 drivers/net/ 目录中创建驱动子目录

示例如下：

```bash
 drivers/net/ice/
```
## 3. 修改 mk/rte.app.mk 文件，添加一个链接项目

示例如下：

```Makefile
_LDLIBS-$(CONFIG_RTE_LIBRTE_ICE_PMD)       += -lrte_pmd_ice
```

## 4. 修改 drivers/net/Makefile 文件，添加新驱动目录

示例如下：
```bash
DIRS-$(CONFIG_RTE_LIBRTE_ICE_PMD)     += ice
```

## 5. config/common_base 中添加新的网卡驱动配置项目

示例如下：

```c
#
# Compile burst-oriented ICE PMD driver
#
CONFIG_RTE_LIBRTE_ICE_PMD=y
CONFIG_RTE_LIBRTE_ICE_DEBUG_RX=n
CONFIG_RTE_LIBRTE_ICE_DEBUG_TX=n
CONFIG_RTE_LIBRTE_ICE_DEBUG_TX_FREE=n
CONFIG_RTE_ICE_INC_VECTOR=n
```

## 6. 重新生成 $RTE_TARGET/.config 中的配置文件

# 驱动需要实现的内容

## 1. drivers/net/xx 目录中添加相关的 Makefile

示例如下：


```mk
# SPDX-License-Identifier: BSD-3-Clause
# Copyright(c) 2018 Intel Corporation

include $(RTE_SDK)/mk/rte.vars.mk

#
# library name
#
LIB = librte_pmd_ice.a

CFLAGS += -O3
CFLAGS += $(WERROR_FLAGS)
CFLAGS += -DALLOW_EXPERIMENTAL_API

LDLIBS += -lrte_eal -lrte_mbuf -lrte_ethdev -lrte_kvargs
LDLIBS += -lrte_bus_pci -lrte_mempool -lrte_hash

EXPORT_MAP := rte_pmd_ice_version.map

#
# Add extra flags for base driver files (also known as shared code)
# to disable warnings
#
ifeq ($(CONFIG_RTE_TOOLCHAIN_ICC),y)
CFLAGS_BASE_DRIVER +=
else ifeq ($(CONFIG_RTE_TOOLCHAIN_CLANG),y)
CFLAGS_BASE_DRIVER += -Wno-unused-parameter
CFLAGS_BASE_DRIVER += -Wno-unused-variable
else
CFLAGS_BASE_DRIVER += -Wno-unused-parameter
CFLAGS_BASE_DRIVER += -Wno-unused-variable

ifeq ($(shell test $(GCC_VERSION) -ge 44 && echo 1), 1)
CFLAGS_BASE_DRIVER += -Wno-unused-but-set-variable
endif

endif
OBJS_BASE_DRIVER=$(patsubst %.c,%.o,$(notdir $(wildcard $(SRCDIR)/base/*.c)))
$(foreach obj, $(OBJS_BASE_DRIVER), $(eval CFLAGS_$(obj)+=$(CFLAGS_BASE_DRIVER)))

VPATH += $(SRCDIR)/base

#
# all source are stored in SRCS-y
#
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_controlq.c
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_common.c
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_sched.c
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_switch.c
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_nvm.c
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_flex_pipe.c
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_flow.c

SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_ethdev.c
SRCS-$(CONFIG_RTE_LIBRTE_ICE_PMD) += ice_rxtx.c

include $(RTE_SDK)/mk/rte.lib.mk
```

## 2. 对接 DPDK PMD pci 驱动框架

### 1. 驱动注册接口
```c
PMD_REGISTER_DRIVER(rte_xxx_driver);
```

### 实现 rte_xxx_driver 结构体

示例内容如下：
```c
static struct rte_driver rte_ice_driver = {
    .type = PMD_PDEV,
    .init = rte_ice_pmd_init,
};
```

### 实现 struct eth_driver 结构体定义

示例内容如下：

```c
static struct eth_driver rte_ice_pmd = {
	.pci_drv = {
		.name = "rte_ice_pmd",
		.id_table = pci_id_ice_map,
		.drv_flags = RTE_PCI_DRV_NEED_MAPPING | RTE_PCI_DRV_INTR_LSC |
			RTE_PCI_DRV_DETACHABLE,
	},
	.eth_dev_init = ice_dev_init,
	.eth_dev_uninit = ice_dev_uninit,
	.dev_private_size = sizeof(struct ice_adapter),
};
```
## 驱动初始化接口与 dpdk pci 框架的对接
驱动实例化的 eth_driver 结构中，eth_dev_init 函数完成与 dpdk pci 框架对接过程。当接口 match 到一个驱动时，调用驱动 eth_driver 结构中的 eth_dev_init 函数前 pci 框架完成了如下任务：

1. 当前接口的 pci 信息已经保存到了一个 rte_pci_device 结构中
2. 当前接口的前 6 个 bar 空间的物理地址已经被映射为用户态虚拟地址
3. 当前接口已经分配了一个 rte_eth_dev 结构并建立起与对应 rte_pci_device 结构的关联
4. 当前接口对应的 rte_eth_dev 结构的 data 结构被分配并进行了一些初始化
5. 当前接口分配的 rte_eth_dev 结构中 data 结构体的 dev_private 变量区域被创建
6. 当前接口分配的 rte_eth_dev 结构中的链路回调函数链表被初始化
7. 当前接口的默认 mtu 被设置

每一种驱动实例化的 eth_dev_init 函数正是基于上面这些环境完成与 pci 框架的对接，关键过程如下：

1. 将 dev->data->dev_private 地址转化为驱动内部结构地址
2. 注册驱动实例化的 eth_dev_ops 到 dev->dev_ops 中，对接 ethdev 层提供的外部接口
3. 将寄存器所在的 bar 的虚拟地址吸入到驱动内部数据结构的某个变量中，intel 的网卡一般叫做 hw_addr
4. 使用 dev->pci_dev 中的字段填充驱动内部数据结构
5. 根据当前接口的 device id，确定具体的 mac 类型
6. 初始化驱动内部分层对象虚函数表，如 eeprom_operations、mac_operations、phy_operations、link_operations、mbx_operations 等函数表
7. 执行接口 reset 后执行其它硬件初始化操作
9. 注册中断回调函数后使能中断

## 3. eth_dev_ops 驱动底层接口实现

需要实现一个 xxx_eth_dev_ops，这些驱动由 rte_ethdev.c 中封装的接口调用。

示例内容如下：

```c
static const struct eth_dev_ops ice_eth_dev_ops = {
	.dev_configure                = ice_dev_configure,
	.dev_start                    = ice_dev_start,
	.dev_stop                     = ice_dev_stop,
	.dev_close                    = ice_dev_close,
	.rx_queue_start               = ice_rx_queue_start,
	.rx_queue_stop                = ice_rx_queue_stop,
	.tx_queue_start               = ice_tx_queue_start,
	.tx_queue_stop                = ice_tx_queue_stop,
	.rx_queue_setup               = ice_rx_queue_setup,
	.rx_queue_release             = ice_rx_queue_release,
	.tx_queue_setup               = ice_tx_queue_setup,
	.tx_queue_release             = ice_tx_queue_release,
	.dev_infos_get                = ice_dev_info_get,
	.dev_supported_ptypes_get     = ice_dev_supported_ptypes_get,
	.link_update                  = ice_link_update,
	.mtu_set                      = ice_mtu_set,
	.mac_addr_set                 = ice_macaddr_set,
	.mac_addr_add                 = ice_macaddr_add,
	.mac_addr_remove              = ice_macaddr_remove,
	.vlan_filter_set              = ice_vlan_filter_set,
	.vlan_offload_set             = ice_vlan_offload_set,
	.vlan_tpid_set                = ice_vlan_tpid_set,
	.reta_update                  = ice_rss_reta_update,
	.reta_query                   = ice_rss_reta_query,
	.rss_hash_update              = ice_rss_hash_update,
	.rss_hash_conf_get            = ice_rss_hash_conf_get,
	.promiscuous_enable           = ice_promisc_enable,
	.promiscuous_disable          = ice_promisc_disable,
	.allmulticast_enable          = ice_allmulti_enable,
	.allmulticast_disable         = ice_allmulti_disable,
	.rx_queue_intr_enable         = ice_rx_queue_intr_enable,
	.rx_queue_intr_disable        = ice_rx_queue_intr_disable,
	.get_eeprom_length            = ice_get_eeprom_length,
	.get_eeprom                   = ice_get_eeprom,
	.stats_get                    = ice_stats_get,
	.stats_reset                  = ice_stats_reset,
	.xstats_get                   = ice_xstats_get,
	.xstats_reset                 = ice_stats_reset,
};
```
主要功能划分如下：

| 功能                               | 函数                                                         |
| ---------------------------------- | ------------------------------------------------------------ |
| 接口配置                           | dev_configure                                                |
| 接口 down、up                      | dev_start、dev_stop                                          |
| 接口释放                           | dev_close                                                    |
| 接收、发送队列配置                 | rx/tx_queue_start、rx/tx_queue_stop、rx/tx_queue_setup、rx/tx_queue_release |
| 获取接口的默认配置值               | dev_infos_get                                                |
| 获取接口当前链路状态               | link_update                                                  |
| 设置接口 mtu                       | mtu_set                                                      |
| mac 地址的设置、添加、删除         | mac_addr_set/add/remove                                      |
| vlan 过滤、卸载、tpid 设置         | vlan_filter_set、vlan_offload_set、vlan_tpid_set             |
| 接口 hash key 获取与配置           | rss_hash_update、rss_hash_update                             |
| 混淆模式、多播广播模式的开启与关闭 | promiscuous_enable/disable 、allmulticast_enable/disable     |
| 收发队列中断配置                   | rx/tx_queue_intr_enable                                      |
| 网卡 eeprom 内容获取               | get_eeprom_length、get_eeprom                                |
| 接口收发统计信息获取与清零         | stats_get/reset、xstats_get/reset                            |

## 4. 实现网卡收发包接口

收包接口示例：

```c
uint16_t
ice_recv_pkts(void *rx_queue,
	      struct rte_mbuf **rx_pkts,
	      uint16_t nb_pkts)
```

发包接口示例：

```c
uint16_t
ice_xmit_pkts(void *tx_queue, struct rte_mbuf **tx_pkts, uint16_t nb_pkts)
```
收发包接口通过填充当前接口分配的 rte_eth_dev 结构中的 rxa_pkt_burst、tx_pkt_burst 完成。存在多套收发包接口时，一般通过一个 xxx_set_rx/tx_function 函数来探测当前配置应该使用的收发包函数实例。

不同的发包函数有各自依赖的配置，这些配置必须独立。

## dpdk poll mode 收发包的原理
dpdk poll mode 依赖 dma 来完成报文从网卡到主机内存及反向过程，在描述前先从 ldd3 中翻译如下信息：

### User virtual addresses
用户态虚拟地址是用户态程序可见的普通地址。用户地址有 32-bit、64-bit 长度，依赖具体的硬件架构，每一种处理器都有自己的虚拟地址空间。
### Physical addresses
这个地址用于处理器与系统内存之间的交互。物理地址是 32、64 位宽度的，一些 32 位系统在一些情况下也能够使用更大的物理地址。

### Bus addresses
这个地址在外设总线与内存之间被使用。通常情况下，它与处理器使用的物理地址一致，但是并不是所有情况都是这样。一些架构支持 IOMMU 机制，通过 IOMMU 完成一个总线与主机内存间访问地址的重映射。

### dma 数据传输的两种类别

1. 软件同步请求数据
2. 硬件异步推送数据到系统中

软件同步请求数据主要过程如下：

1. 当一个程序调用 read 时，驱动中的方法盛情一个 DMA 缓冲区并控制硬件将数据传输到这个缓冲区中。进程进入睡眠状态。
2. 硬件将数据写入到 DMA 缓冲区中，完成后触发一个中断信号。
3. 中断处理程序获取到输入数据，清除中断标志并且唤醒进程，这时进程就能够读取数据了。

硬件异步推送数据到系统中的主要过程如下：

1. 硬件触发一个中断信号声明新的数据已经到达
2. 中断处理程序创建一个缓冲区并告诉硬件该将新的数据传输到哪里
3. 外设将数据写入到缓冲区中，完成后出发另外一个中断信号
4. 中断处理程序分发新数据，唤醒相关进程并完成其它流程处理

一个异步方法的变体在网卡中被广泛使用。这些网卡预期看到一个环形缓冲区（又称为一个 DMA ring buffer）在内存中建立并与处理器共享，每一个收到的报文都被放到下一个 ring 中可用的 buffer 中，并触发一个中断信号。

此后，驱动负责将网络报文投递到内核的其它模块中并且将一个新的 DMA buffer 放到 ring 中。

### DMA buffer 的问题
DMA buffer 存在的一个主要问题是，当其大小大于一个物理页时，由于设备数据传输使用 ISA、PCI 系统总线，他们都使用物理地址，因此分配的空间必须在物理内存中占据连续的页。奇特的是这一规则并不适用于 SBus，SBus 在外设总线上使用虚拟地址。

### Bus Addresses
使用DMA的设备驱动程序必须与连接到接口总线的硬件进行通信，它使用物理地址，而程序代码使用虚拟地址。 事实上，情况比这稍微复杂一些。 基于 DMA 的硬件使用总线地址而非物理地址。尽管 ISA 和 PCI 总线地址在 PC 上就是普通的物理地址，这一点并不适用于每一个平台。

在尝试使用 DMA 之前必须回答的第一个问题是给定的设备是否能够在当前主机上执行这样的操作。许多设备由于各种原因，所能寻址的内存范围有限。默认情况下，内核假设你的设备能够对任意 32-bit 地址执行 DMA 操作。如果这个假设不成立，你需要通过调用 dma_set_mask 通知内核真实的地址位数限制。

### pci 代码的两种 DMA 映射类型
PCI代码区分两种DMA映射类型，按照 DMA 缓冲区的生命周期进行区分。


1. 一致性DMA映射

这些映射通常存在于驱动程序的生命周期中。必须有一个一致的缓冲区同时用于 CPU 和外围设备。因此，相干映射必须存在于一致性 cache 内存区域中。

2. 流式DMA映射

流映射通常为单个操作设置。一些架构允许在使用流映射时进行多种优化，但是这些映射也受到一组更严格规则的约束来控制访问。内核开发人员建议优先使用流映射而非一致性映射。

这一建议基于如下两个原因：
1. 在支持映射寄存器的系统上，每个 DMA 映射在总线上使用一个或多个寄存器。一致性映射有一个非常长的生命周期，在不使用的时候也一直独占这些寄存器。
2. 在一些硬件上，流映射可以使用一致性映射不支持的方式进行优化。

### dpdk poll mode 通过 DMA 收发包
有了上面对 DMA 的认识后，开始描述 dpdk 通过 PMD 对 DMA 使用及收发包的关键过程。

1. 网卡接口绑定到 igb_uio，设置接口 dma_mask 并通知内核
2. 调用  rte_eth_dma_zone_reserve 创建每个队列上的收发硬件描述符 dma 区域，申请出的区域在物理页上连续
3. 根据网卡手册初始化描述符中的必要字段，并将申请到的用于收发描述符的 dma 区域的起始地址转化为物理地址保存到队列结构的某个字段中
4. 将收发描述符起始地址的物理地址及总长度写入到寄存器中并将保存描述符头尾位置的寄存器值清零
5. 为每一个收包队列申请 nb_rx_desc 个 mbuf，对 mbuf 执行相应的初始化后将 mbuf dataroom 所在的区域的物理地址写入到每个接收描述符的字段中
6. 设置接收、发送描述符控制寄存器、设置接收、发送控制寄存器等等必要的寄存器，开启收发包

备注：上述过程中不包含其它依赖的硬件操作，这些操作需要按照网卡 datasheet 来配置
#### 网卡与驱动侧收包过程
当网卡收到包后，phy 与 mac 层有相对复杂的处理过程。一个正常的报文通过了这些处理过程后，最终被存放到网卡的 fifo 中，此后网卡侧关键过程如下：

1. 网卡 mac 层获取到当前硬件可用的 rx 描述符的位置，获取到描述符中预先配置的 mbuf dataroom 的物理地址，触发一个 DMA 操作，将报文从网卡 fifo 中拷贝到 mbuf dataroom 指向的物理地址中，这是零拷贝的基础。
2. 网卡更新内部维持描述符位置状态的寄存器
3. 网卡重复这样的过程，直到获取不到一个空闲的描述符

当描述符都被填充满后新到的包如何处理依赖网卡芯片的设计。

dpdk 驱动侧收包过程：

1. 程序主动调用驱动中实现的收包函数，获取当前软件可用的描述符的位置，判断描述符中标志存在报文的变量，当判断通过后处理报文
2. 获取软件维护的当前已经填充了报文的描述符对应的 mbuf 的地址，将描述符中的字段映射到 mbuf 头中的字段中，然后申请一个新的 mbuf 继续填入到 rx ring 中，最后更新网卡维持描述符位置的某个寄存器通知硬件。
3. dpdk 向上层程序返回收到的包的个数及保存 mbuf 地址的指针数组

这里存在一个问题：当驱动侧获取到一个填充了报文的描述符后，驱动会创建一个新的 mbuf 并将其 dataroom 的物理地址填充到当前的描述符中的相关字段中，如果硬件不能更新这个描述符中标志已经收到报文的变量，就需要软件设置。

#### 网卡与驱动侧发包过程
1. dpdk 程序填充待发送的报文，通过调用 rte_eth_tx_burst 发送
2. 网卡驱动底层的发包函数依次遍历上层传入的报文，获取空闲的 tx 描述符，并使用 mbuf 头中的字段填充描述符
3. 填充描述符的关键在于将 mbuf dataroom 区域起始地址的物理地址写入到 tx 描述符中
4. 最后更新网卡中维护发送描述符位置的寄存器通知网卡有新的报文需要发送
5. 网卡获取到绑定了报文的发送描述符，将报文拷贝到发送 fifo 中后经过一系列硬件操作后发送出去，发送完成后更新必要的寄存器值

# 总结
dpdk pmd 新驱动的开发相对困难，一方面由驱动框架的复杂性决定，一方面由网卡驱动自身的复杂性决定。本文中梳理了开发一个新的网卡驱动的主要过程，重点放在如何与 dpdk pci 框架、收发包框架对接上，这是本文的重点。实际上，一个网卡驱动的开发是非常复杂的，可关键的过程也就那几步，能够认识这几步并搞清楚其内部的原理，这才是向核心靠拢的过程。