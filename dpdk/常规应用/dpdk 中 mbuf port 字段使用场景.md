# dpdk 中 mbuf port 字段使用场景分析
## 前言
某产品的数通引擎持续运行一段时候后出现段错误，排查段错误发现访问的 mbuf 中的 port 字段变为了-1（全 F），需要排查 dpdk 内部对 mbuf 中 port 字段的使用情况。

## 版本信息
dpdk 版本：dpdk-16.04
网卡型号：x710 网卡
驱动类型：i40e 驱动
## mbuf pool 创建时

rte_pktmbuf_pool_create 函数创建 mbuf pool 的时候，会调用 rte_pktmbuf_init 接口对每一个 mbuf 的 port 字段进行初始化，赋值为 -1。

主要代码如下：

```c
void
rte_pktmbuf_init(struct rte_mempool *mp,
		 __attribute__((unused)) void *opaque_arg,
		 void *_m,
		 __attribute__((unused)) unsigned i)
{
	struct rte_mbuf *m = _m;
	uint32_t mbuf_size, buf_len, priv_size;

............................................

	/* init some constant fields */
	m->pool = mp;
	m->nb_segs = 1;
	m->port = 0xff;
}
```
## 驱动 start rx queue 时 
在 dpdk start 接口的过程中驱动会为每一个收包队列上的描述符分配 mbuf，i40e 驱动中调用自己封装的 rte_rxmbuf_alloc 函数来分配 mbuf，其源码如下：
```c
static inline struct rte_mbuf *
rte_rxmbuf_alloc(struct rte_mempool *mp)
{
	struct rte_mbuf *m;

	m = __rte_mbuf_raw_alloc(mp);
	__rte_mbuf_sanity_check_raw(m, 0);

	return m;
}
```
核心是调用 ```__rte_mbuf_raw_alloc```函数来实现，此函数中并不会操作 mbuf 中的 port 字段。

i40e_alloc_rx_queue_mbufs 函数调用 rte_rxmbuf_alloc 函数后会将申请到的 mbuf  port 字段填充为当前队列所在 port，主要代码如下：
```c
int
i40e_alloc_rx_queue_mbufs(struct i40e_rx_queue *rxq)
{
	struct i40e_rx_entry *rxe = rxq->sw_ring;
	uint64_t dma_addr;
	uint16_t i;

	for (i = 0; i < rxq->nb_rx_desc; i++) {
		volatile union i40e_rx_desc *rxd;
		struct rte_mbuf *mbuf = rte_rxmbuf_alloc(rxq->mp);

		.................
		mbuf->port = rxq->port_id;
		.................
	}
```

## 驱动收包函数中对 mbuf port 字段的使用
驱动收包函数一般是在拿走 mbuf 的同时申请 mbuf 重新填充到描述符上。

按照 mbuf 的个数可以分为两种类型：
1. 拿走一个同时分配一个
2. 拿走多个同时分配多个

对于第一种模型 i40e 收包函数调用上文提到的 rte_rxmbuf_alloc 函数，此函数并不会初始化 mbuf 的 port 字段，这个字段在驱动收包函数中填充为当前收包队列所在的 port。

第二种模型下，i40e 调用 rte_mempool_get_bulk 同时分配多个 mbuf，并在成功分配后将 mbuf 的 port 字段赋值为当前收包队列所在的 port。

主要代码如下：
```c
	diag = rte_mempool_get_bulk(rxq->mp, (void *)rxep,
					rxq->rx_free_thresh);

	...............................
	for (i = 0; i < rxq->rx_free_thresh; i++) {
	...............................
		mb->port = rxq->port_id;
		dma_addr = rte_cpu_to_le_64(\
			rte_mbuf_data_dma_addr_default(mb));
		rxdp[i].read.hdr_addr = 0;
		rxdp[i].read.pkt_addr = dma_addr;
	}
	...............................
```
rx_free_thresh 控制多次申请 mbuf 的门限，一般为 32。

## 驱动发包函数中对 mbuf port 的使用
表面看来驱动发包函数应该用不到 mbuf port 的字段，其实并不完全正确。发包函数中存在释放 mbuf 的过程，这一过程中可能潜藏着对 mbuf port 字段的重置。

i40e 发包函数中释放 mbuf 的典型代码如下：
```c
			if (txe->mbuf)
				rte_pktmbuf_free_seg(txe->mbuf);
			txe->mbuf = m_seg;
```
这里的 m_seg 代表新的报文，这里的逻辑是将新的报文填充到 txe 的 mbuf 字段上。在填充前判断如果 txe 的 mbuf 字段不为空就释放上面的 mbuf（此 mbuf 代表的报文已经被网卡成功发送）。

排查 rte_pktmbuf_free_seg 接口，确认不会对 port 字段赋值。
## 其它可用的申请 mbuf 接口对 port 字段的使用情况
| 函数接口 | 修改 port 值 |
|--|--|
| rte_pktmbuf_alloc|  设置为 -1|
|rte_mempool_get_bulk | 不修改|
|__rte_mbuf_raw_alloc | 不修改 |
| rte_pktmbuf_clone | 修改为目标 mbuf 的 port 值|
|rte_pktmbuf_attach| 修改为目标 mbuf 的 port 值 |
| rte_pktmbuf_reset| 设置为 -1|
|rte_pktmbuf_alloc_bulk| 设置为 -1|

## mbuf 释放时对 port 字段的使用
释放 mbuf 时不会赋值 port 字段。

## 总结
经过梳理确认 dpdk 中对 mbuf port 字段的使用并没有明显的异常，不过确实发现了一些可能会将 mbuf 中的 port 字段设置为 -1 的接口，可以从对这些接口的调用入手进一步排查数通引擎内部的逻辑。

