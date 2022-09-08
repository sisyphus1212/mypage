# x710 offload QinQ 报文 vlan 并支持 rss hash 到多队列
## 问题描述
对于五元组随机变化的 QinQ 报文，需要实现如下需求：
1. dpdk 程序 rx 时网卡自动剥掉外层 vlan 头
2. dpdk 程序 tx 时网卡自动添加一个指定的 vlan 头
3. 报文能够 hash 到不同的队列上
4. 基于 dpdk-19.11 版本与 x710 网卡

## QinQ 报文的格式
如下图所示，QinQ 其实可以简单的理解为 vlan 里面套了 vlan 的形式，QinQ 写成 802.1Q in 802.1 Q 可能更形象一点。
![!\[在这里插入图片描述\](https://img-blog.csdnimg.cn/4542618bf0424b6aa569f2cdeda5340f.png](https://img-blog.csdnimg.cn/bc76e9f19588499695bfd4399ddef2f3.png)上图摘自：https://www.cnblogs.com/sddai/p/6204496.html

对 QinQ 报文有基础的认识后，继续研究相关需求如何实现。

## dpdk 程序 rx 时如何实现网卡自动剥掉外层 vlan？
dpdk 支持如下网卡 rx mode 配置：

```c
#define DEV_RX_OFFLOAD_VLAN_STRIP  0x00000001
#define DEV_RX_OFFLOAD_IPV4_CKSUM  0x00000002
#define DEV_RX_OFFLOAD_UDP_CKSUM   0x00000004
#define DEV_RX_OFFLOAD_TCP_CKSUM   0x00000008
#define DEV_RX_OFFLOAD_TCP_LRO     0x00000010
#define DEV_RX_OFFLOAD_QINQ_STRIP  0x00000020
#define DEV_RX_OFFLOAD_OUTER_IPV4_CKSUM 0x00000040
#define DEV_RX_OFFLOAD_MACSEC_STRIP     0x00000080
#define DEV_RX_OFFLOAD_HEADER_SPLIT	0x00000100
#define DEV_RX_OFFLOAD_VLAN_FILTER	0x00000200
#define DEV_RX_OFFLOAD_VLAN_EXTEND	0x00000400
#define DEV_RX_OFFLOAD_JUMBO_FRAME	0x00000800
#define DEV_RX_OFFLOAD_SCATTER		0x00002000
#define DEV_RX_OFFLOAD_TIMESTAMP	0x00004000
#define DEV_RX_OFFLOAD_SECURITY         0x00008000
#define DEV_RX_OFFLOAD_KEEP_CRC		0x00010000
#define DEV_RX_OFFLOAD_SCTP_CKSUM	0x00020000
#define DEV_RX_OFFLOAD_OUTER_UDP_CKSUM  0x00040000
#define DEV_RX_OFFLOAD_RSS_HASH		0x00080000
```
**DEV_RX_OFFLOAD_VLAN_STRIP** 这个 offload 使能后网卡会**自动剥掉最外层的 vlan**，同时 **vlan 信息** 会保存到**收包描述符**的特定字段上。

dpdk 驱动收包函数中会将描述符上的 vlan 信息转化并保存到 mbuf 中的 **vlan_tci** 字段中，上层程序通过访问 mbuf 的这个字段就能够获取到报文的 **vlan** 了。

这些 rx offloads 通过 rxmode 配置。dpdk 程序调用 rte_eth_dev_configure 函数时驱动层判段 rxmode 并执行相关的硬件初始化，示例代码如下：

```c
local_port_conf.rxmode.offloads |=
         DEV_RX_OFFLOAD_VLAN_STRIP;
ret = rte_eth_dev_configure(portid, 1, 1, &local_port_conf);
```

dpdk i40e 普通收包函数中有如下关键代码：
```c
 116 i40e_rxd_to_vlan_tci(struct rte_mbuf *mb, volatile union i40e_rx_desc *rxdp)
 117 {
 118     if (rte_le_to_cpu_64(rxdp->wb.qword1.status_error_len) &
 119         (1 << I40E_RX_DESC_STATUS_L2TAG1P_SHIFT)) {
 120         mb->ol_flags |= RTE_MBUF_F_RX_VLAN | RTE_MBUF_F_RX_VLAN_STRIPPED;
 121         mb->vlan_tci =
 122             rte_le_to_cpu_16(rxdp->wb.qword0.lo_dword.l2tag1);
 123         PMD_RX_LOG(DEBUG, "Descriptor l2tag1: %u",
 124                rte_le_to_cpu_16(rxdp->wb.qword0.lo_dword.l2tag1));
 125     } else {
 126         mb->vlan_tci = 0;
 127     }
```
描述符中的字段由网卡硬件填充，在驱动收包函数中被转化存储到 mbuf 的 vlan_tci 字段中，这就是剥离 vlan 头 offload 的关键过程。

## dpdk 程序如何在发包时让网卡自动添加一个指定的 vlan 头？https://dev.dpdk.narkive.com/lCYIb96o/dpdk-vlan-header-insertion-and-removal
与 rx 类似，发包时添加 vlan 头也可以通过配置 tx offload 来使能。需要注意的是添加的 vlan 头需要的信息上层要在发包前填充到 dpdk mbuf 的指定字段上，这一点与收包过程刚好相反。

dpdk 支持的 tx offload 部分摘录:
```c
#define DEV_TX_OFFLOAD_VLAN_INSERT 0x00000001
#define DEV_TX_OFFLOAD_IPV4_CKSUM  0x00000002
#define DEV_TX_OFFLOAD_UDP_CKSUM   0x00000004
#define DEV_TX_OFFLOAD_TCP_CKSUM   0x00000008
#define DEV_TX_OFFLOAD_SCTP_CKSUM  0x00000010
#define DEV_TX_OFFLOAD_TCP_TSO     0x00000020
#define DEV_TX_OFFLOAD_UDP_TSO     0x00000040
#define DEV_TX_OFFLOAD_OUTER_IPV4_CKSUM 0x00000080 /**< Used for tunneling packet. */
#define DEV_TX_OFFLOAD_QINQ_INSERT 0x00000100
```
这些 offloads 通过 txmode 配置，在 dpdk 程序调用 rte_eth_dev_configure 函数时被使用，示例代码如：
```c
local_port_conf.txmode.offloads |=
         DEV_TX_OFFLOAD_VLAN_INSERT;
ret = rte_eth_dev_configure(portid, 1, 1, &local_port_conf);
```
发包前上层应用对 mbuf vlan 相关字段填充信息示例：
```c
mbufs[idx]->vlan_tci = 0xef00;
mbufs[idx]->ol_flags |= PKT_TX_VLAN_PKT;
```
这里存在的一个问题是，i40e 驱动的向量发包函数不支持 DEV_TX_OFFLOAD_VLAN_INSERT offload，配置了 DEV_TX_OFFLOAD_VLAN_INSERT offload 时只能使用普通的发包函数，不能使用向量发包函数。
### 报文 hash 到不同的队列上
要让报文 hash 到不同的队列上，可以通过配置网卡的 rss hash 功能来实现。测试对 **QinQ** 报文的 hash 时却发现存在如下问题：

x710 网卡必须**同时配置 rss hash 与 rx vlan extend offload** 才能 hash 到不同的队列上，r**x vlan strip offload** 是否配置不影响 hash 结果。

同时观测到如下现象：

1. x710 网卡同时配置了 rx vlan strip offload 与 rx vlan extend offload 时，QinQ 报文的两层 vlan 都被剥掉。
2. 配置了 rx vlan extend offload 后，tx VLAN_INSERT offload 失效。
3. 单独使能 rx vlan extend offload 与 rx vlan strip offload 效果相同

经过其它的尝试，没有找到可用的方案。**为了保证 rss hash 功能可用只能开启 rx vlan extend offload 同时上层在发包时软件添加 vlan 头。**
## 提问环节
1. vlan extend 是什么？
	代码里面有注释表明 vlan extend 是 double vlan，网上搜索不到相关的信息。
2. 通过配置 DEV_RX_OFFLOAD_QINQ_STRIP 是否能够 hash 开？
	环境限制，无法测试，只能暂且放弃了。

## 参考链接
https://dev.dpdk.narkive.com/XcHzHsvq/dpdk-rss-for-double-vlan-tagged-packets

https://doc.dpdk.org/api-2.2/structrte__eth__rxmode.html

https://linkthedevil.gitbook.io/little-things-about-dataplane/3

https://dev.dpdk.narkive.com/lCYIb96o/dpdk-vlan-header-insertion-and-removal

