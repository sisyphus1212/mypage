# dpdk 问题分析：dpdk-19.11 性能优于 dpdk-16.04 问题分析
## 问题描述

**某飞腾 arm 设备**，运行 dpdk-19.11 l2fwd，**两个核小包纯转发**在 **55% 以上**，运行 dpdk-16.04 l2fwd，**两个核小包纯转发 21%**。

**小包性能远低于预期！**

备注：绑核情况相同！

## 问题分析

1. dpdk-19.11 优化了 rte_mbuf 中的结构，对性能有影响
2. dpdk-19.11 l2fwd 使用的描述符的数量与 dpdk-16.04 l2fwd 可能存在**差异**
3. dpdk-19.11 rte_mbuf 结构调整，arm neno 向量收发包函数有几个指令的优化，性能要比 dpdk-16.04 更优，但是差别不会特别大
4. 设备架构为单 numa 结构，不存在跨 numa 问题

**在 x86 上，dpdk-19.11 在一些平台能够使用 avx2、avx512 收发包函数，对小包性能有明显的优化。**

主要分析方向：
1. 确认描述符数量差异 
2. 确认向量收发包函数差异
3. 确认其它配置上的差异

## 描述符数量差异
### dpdk-16.04

#define RTE_TEST_RX_DESC_DEFAULT 128
#define RTE_TEST_TX_DESC_DEFAULT 512

### dpdk-19.11

#define RTE_TEST_RX_DESC_DEFAULT 1024
#define RTE_TEST_TX_DESC_DEFAULT 1024

差异分析结论：**dpdk-19.11 配置的描述符数量高于 dpdk-16.04**。
## 每个 mempool 的 cache size 大小差异
### dpdk-16.04
#define MEMPOOL_CACHE_SIZE 32

### dpdk-19.11
#define MEMPOOL_CACHE_SIZE 256

差异分析结论：**dpdk-19.11 配置的 mempool 的 cache_size 的大小是 dpdk-16.04 的 8 倍**。
## 向量收发包函数实现差异
diff 对比得到的差异点：
```c
git diff   ~/dpdk-16.04/drivers/net/i40e/i40e_rxtx_vec_neon.c  ~/dpdk-19.11/drivers/net/i40e/i40e_rxtx_vec_neon.c
--- a/home/longyu/dpdk-16.04/drivers/net/i40e/i40e_rxtx_vec_neon.c
+++ b/home/longyu/dpdk-19.11/drivers/net/i40e/i40e_rxtx_vec_neon.c

#include <stdint.h>
-#include <rte_ethdev.h>
+#include <rte_ethdev_driver.h>
 #include <rte_malloc.h>

 #include "base/i40e_prototype.h"
@@ -57,7 +28,6 @@ i40e_rxq_rearm(struct i40e_rx_queue *rxq)
        uint64x2_t dma_addr0, dma_addr1;
        uint64x2_t zero = vdupq_n_u64(0);
        uint64_t paddr;
-       uint8x8_t p;

        rxdp = rxq->rx_ring + rxq->rxrearm_start;

@@ -77,28 +47,18 @@ i40e_rxq_rearm(struct i40e_rx_queue *rxq)
                return;
        }

-       p = vld1_u8((uint8_t *)&rxq->mbuf_initializer);
-
        /* Initialize the mbufs in vector, process 2 mbufs in one loop */
        for (i = 0; i < RTE_I40E_RXQ_REARM_THRESH; i += 2, rxep += 2) {
                mb0 = rxep[0].mbuf;
                mb1 = rxep[1].mbuf;

-                /* Flush mbuf with pkt template.
-                * Data to be rearmed is 6 bytes long.
-                * Though, RX will overwrite ol_flags that are coming next
-                * anyway. So overwrite whole 8 bytes with one load:
-                * 6 bytes of rearm_data plus first 2 bytes of ol_flags.
-                */
-               vst1_u8((uint8_t *)&mb0->rearm_data, p);
-               paddr = mb0->buf_physaddr + RTE_PKTMBUF_HEADROOM;
+               paddr = mb0->buf_iova + RTE_PKTMBUF_HEADROOM;
                dma_addr0 = vdupq_n_u64(paddr);

                /* flush desc with pa dma_addr */
                vst1q_u64((uint64_t *)&rxdp++->read, dma_addr0);

-               vst1_u8((uint8_t *)&mb1->rearm_data, p);
-               paddr = mb1->buf_physaddr + RTE_PKTMBUF_HEADROOM;
+               paddr = mb1->buf_iova + RTE_PKTMBUF_HEADROOM;
                dma_addr1 = vdupq_n_u64(paddr);
                vst1q_u64((uint64_t *)&rxdp++->read, dma_addr1);
        }
@@ -116,18 +76,13 @@ i40e_rxq_rearm(struct i40e_rx_queue *rxq)
        I40E_PCI_REG_WRITE(rxq->qrx_tail, rx_id);
 }

-/* Handling the offload flags (olflags) field takes computation
- * time when receiving packets. Therefore we provide a flag to disable
- * the processing of the olflags field when they are not needed. This
- * gives improved performance, at the cost of losing the offload info
- * in the received packet
- */
-#ifdef RTE_LIBRTE_I40E_RX_OLFLAGS_ENABLE
-
 static inline void
-desc_to_olflags_v(uint64x2_t descs[4], struct rte_mbuf **rx_pkts)
+desc_to_olflags_v(struct i40e_rx_queue *rxq, uint64x2_t descs[4],
+                 struct rte_mbuf **rx_pkts)
 {
        uint32x4_t vlan0, vlan1, rss, l3_l4e;
+       const uint64x2_t mbuf_init = {rxq->mbuf_initializer, 0};
+       uint64x2_t rearm0, rearm1, rearm2, rearm3;

        /* mask everything except RSS, flow director and VLAN flags
         * bit2 is for VLAN tag, bit11 for flow director indication
@@ -136,10 +91,24 @@ desc_to_olflags_v(uint64x2_t descs[4], struct rte_mbuf **rx_pkts)
        const uint32x4_t rss_vlan_msk = {
                        0x1c03804, 0x1c03804, 0x1c03804, 0x1c03804};

+       const uint32x4_t cksum_mask = {
+                       PKT_RX_IP_CKSUM_GOOD | PKT_RX_IP_CKSUM_BAD |
+                       PKT_RX_L4_CKSUM_GOOD | PKT_RX_L4_CKSUM_BAD |
+                       PKT_RX_EIP_CKSUM_BAD,
+                       PKT_RX_IP_CKSUM_GOOD | PKT_RX_IP_CKSUM_BAD |
+                       PKT_RX_L4_CKSUM_GOOD | PKT_RX_L4_CKSUM_BAD |
+                       PKT_RX_EIP_CKSUM_BAD,
+                       PKT_RX_IP_CKSUM_GOOD | PKT_RX_IP_CKSUM_BAD |
+                       PKT_RX_L4_CKSUM_GOOD | PKT_RX_L4_CKSUM_BAD |
+                       PKT_RX_EIP_CKSUM_BAD,
+                       PKT_RX_IP_CKSUM_GOOD | PKT_RX_IP_CKSUM_BAD |
+                       PKT_RX_L4_CKSUM_GOOD | PKT_RX_L4_CKSUM_BAD |
+                       PKT_RX_EIP_CKSUM_BAD};
+
        /* map rss and vlan type to rss hash and vlan flag */
        const uint8x16_t vlan_flags = {
                        0, 0, 0, 0,
-                       PKT_RX_VLAN_PKT | PKT_RX_VLAN_STRIPPED, 0, 0, 0,
+                       PKT_RX_VLAN | PKT_RX_VLAN_STRIPPED, 0, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0};

@@ -150,14 +119,16 @@ desc_to_olflags_v(uint64x2_t descs[4], struct rte_mbuf **rx_pkts)
                        0, 0, 0, 0};

        const uint8x16_t l3_l4e_flags = {
-                       0,
-                       PKT_RX_IP_CKSUM_BAD,
-                       PKT_RX_L4_CKSUM_BAD,
-                       PKT_RX_L4_CKSUM_BAD | PKT_RX_IP_CKSUM_BAD,
-                       PKT_RX_EIP_CKSUM_BAD,
-                       PKT_RX_EIP_CKSUM_BAD | PKT_RX_IP_CKSUM_BAD,
-                       PKT_RX_EIP_CKSUM_BAD | PKT_RX_L4_CKSUM_BAD,
-                       PKT_RX_EIP_CKSUM_BAD | PKT_RX_L4_CKSUM_BAD | PKT_RX_IP_CKSUM_BAD,
+                       (PKT_RX_IP_CKSUM_GOOD | PKT_RX_L4_CKSUM_GOOD) >> 1,
+                       PKT_RX_IP_CKSUM_BAD >> 1,
+                       (PKT_RX_IP_CKSUM_GOOD | PKT_RX_L4_CKSUM_BAD) >> 1,
+                       (PKT_RX_L4_CKSUM_BAD | PKT_RX_IP_CKSUM_BAD) >> 1,
+                       (PKT_RX_IP_CKSUM_GOOD | PKT_RX_EIP_CKSUM_BAD) >> 1,
+                       (PKT_RX_EIP_CKSUM_BAD | PKT_RX_IP_CKSUM_BAD) >> 1,
+                       (PKT_RX_IP_CKSUM_GOOD | PKT_RX_EIP_CKSUM_BAD |
+                        PKT_RX_L4_CKSUM_BAD) >> 1,
+                       (PKT_RX_EIP_CKSUM_BAD | PKT_RX_L4_CKSUM_BAD |
+                        PKT_RX_IP_CKSUM_BAD) >> 1,
                        0, 0, 0, 0, 0, 0, 0, 0};

        vlan0 = vzipq_u32(vreinterpretq_u32_u64(descs[0]),
@@ -177,25 +148,31 @@ desc_to_olflags_v(uint64x2_t descs[4], struct rte_mbuf **rx_pkts)
        l3_l4e = vshrq_n_u32(vlan1, 22);
        l3_l4e = vreinterpretq_u32_u8(vqtbl1q_u8(l3_l4e_flags,
                                              vreinterpretq_u8_u32(l3_l4e)));
-
+       /* then we shift left 1 bit */
+       l3_l4e = vshlq_n_u32(l3_l4e, 1);
+       /* we need to mask out the reduntant bits */
+       l3_l4e = vandq_u32(l3_l4e, cksum_mask);

        vlan0 = vorrq_u32(vlan0, rss);
        vlan0 = vorrq_u32(vlan0, l3_l4e);

-       rx_pkts[0]->ol_flags = vgetq_lane_u32(vlan0, 0);
-       rx_pkts[1]->ol_flags = vgetq_lane_u32(vlan0, 1);
-       rx_pkts[2]->ol_flags = vgetq_lane_u32(vlan0, 2);
-       rx_pkts[3]->ol_flags = vgetq_lane_u32(vlan0, 3);
+       rearm0 = vsetq_lane_u64(vgetq_lane_u32(vlan0, 0), mbuf_init, 1);
+       rearm1 = vsetq_lane_u64(vgetq_lane_u32(vlan0, 1), mbuf_init, 1);
+       rearm2 = vsetq_lane_u64(vgetq_lane_u32(vlan0, 2), mbuf_init, 1);
+       rearm3 = vsetq_lane_u64(vgetq_lane_u32(vlan0, 3), mbuf_init, 1);
+
+       vst1q_u64((uint64_t *)&rx_pkts[0]->rearm_data, rearm0);
+       vst1q_u64((uint64_t *)&rx_pkts[1]->rearm_data, rearm1);
+       vst1q_u64((uint64_t *)&rx_pkts[2]->rearm_data, rearm2);
+       vst1q_u64((uint64_t *)&rx_pkts[3]->rearm_data, rearm3);
 }
-#else
-#define desc_to_olflags_v(descs, rx_pkts) do {} while (0)
-#endif

 #define PKTLEN_SHIFT     10
 #define I40E_UINT16_BIT (CHAR_BIT * sizeof(uint16_t))

 static inline void
-desc_to_ptype_v(uint64x2_t descs[4], struct rte_mbuf **rx_pkts)
+desc_to_ptype_v(uint64x2_t descs[4], struct rte_mbuf **rx_pkts,
+               uint32_t *ptype_tbl)
 {
        int i;
        uint8_t ptype;
@@ -204,7 +181,7 @@ desc_to_ptype_v(uint64x2_t descs[4], struct rte_mbuf **rx_pkts)
        for (i = 0; i < 4; i++) {
                tmp = vreinterpretq_u8_u64(vshrq_n_u64(descs[i], 30));
                ptype = vgetq_lane_u8(tmp, 8);
-               rx_pkts[i]->packet_type = i40e_rxd_pkt_type_mapping(ptype);
+               rx_pkts[i]->packet_type = ptype_tbl[ptype];
        }

 }
@@ -223,6 +200,7 @@ _recv_raw_pkts_vec(struct i40e_rx_queue *rxq, struct rte_mbuf **rx_pkts,
        struct i40e_rx_entry *sw_ring;
        uint16_t nb_pkts_recd;
        int pos;
+       uint32_t *ptype_tbl = rxq->vsi->adapter->ptype_tbl;

        /* mask to shuffle from desc. to mbuf */
        uint8x16_t shuf_msk = {
@@ -307,7 +285,6 @@ _recv_raw_pkts_vec(struct i40e_rx_queue *rxq, struct rte_mbuf **rx_pkts,
                /* Read desc statuses backwards to avoid race condition */
                /* A.1 load 4 pkts desc */
                descs[3] =  vld1q_u64((uint64_t *)(rxdp + 3));
-               rte_rmb();

                /* B.2 copy 2 mbuf point into rx_pkts  */
                vst1q_u64((uint64_t *)&rx_pkts[pos], mbp1);
@@ -330,9 +307,6 @@ _recv_raw_pkts_vec(struct i40e_rx_queue *rxq, struct rte_mbuf **rx_pkts,
                        rte_mbuf_prefetch_part2(rx_pkts[pos + 3]);
                }

-               /* avoid compiler reorder optimization */
-               rte_compiler_barrier();
-
                /* pkt 3,4 shift the pktlen field to be 16-bit aligned*/
                uint32x4_t len3 = vshlq_u32(vreinterpretq_u32_u64(descs[3]),
                                            len_shl);
@@ -356,7 +330,7 @@ _recv_raw_pkts_vec(struct i40e_rx_queue *rxq, struct rte_mbuf **rx_pkts,
                staterr = vzipq_u16(sterr_tmp1.val[1],
                                    sterr_tmp2.val[1]).val[0];

-               desc_to_olflags_v(descs, &rx_pkts[pos]);
+               desc_to_olflags_v(rxq, descs, &rx_pkts[pos]);

                /* D.2 pkt 3,4 set in_port/nb_seg and remove crc */
                tmp = vsubq_u16(vreinterpretq_u16_u8(pkt_mb4), crc_adjust);
@@ -432,7 +406,7 @@ _recv_raw_pkts_vec(struct i40e_rx_queue *rxq, struct rte_mbuf **rx_pkts,
                         pkt_mb2);
                vst1q_u8((void *)&rx_pkts[pos]->rx_descriptor_fields1,
                         pkt_mb1);
-               desc_to_ptype_v(descs, &rx_pkts[pos]);
+               desc_to_ptype_v(descs, &rx_pkts[pos], ptype_tbl);
                /* C.4 calc avaialbe number of desc */
                if (unlikely(stat == 0)) {
                        nb_pkts_recd += RTE_I40E_DESCS_PER_LOOP;
@@ -500,6 +474,7 @@ i40e_recv_scattered_pkts_vec(void *rx_queue, struct rte_mbuf **rx_pkts,
                        i++;
                if (i == nb_bufs)
                        return nb_bufs;
+               rxq->pkt_first_seg = rx_pkts[i];
        }
        return i + reassemble_packets(rxq, &rx_pkts[i], nb_bufs - i,
                &split_flags[i]);
@@ -513,7 +488,7 @@ vtx1(volatile struct i40e_tx_desc *txdp,
                        ((uint64_t)flags  << I40E_TXD_QW1_CMD_SHIFT) |
                        ((uint64_t)pkt->data_len << I40E_TXD_QW1_TX_BUF_SZ_SHIFT));

-       uint64x2_t descriptor = {pkt->buf_physaddr + pkt->data_off, high_qw};
+       uint64x2_t descriptor = {pkt->buf_iova + pkt->data_off, high_qw};
        vst1q_u64((uint64_t *)txdp, descriptor);
 }

@@ -589,7 +564,6 @@ i40e_xmit_fixed_burst_vec(void *tx_queue, struct rte_mbuf **tx_pkts,

        txq->tx_tail = tx_id;

-       rte_wmb();
        I40E_PCI_REG_WRITE(txq->qtx_tail, txq->tx_tail);

        return nb_pkts;
```
差异分析结论：**向量收发包函数的逻辑差异不是太大，dpdk-19.11 增加了一些新的逻辑，此外对 rearm_data 标识处的处理逻辑存在差异，其它过程差异不大**。

## 测试建议
1. 调大 dpdk-16.04 的描述符大小
2. 调大 dpdk-16.04 创建 mempool 时候设置的 cache_size 的值

## 实际的测试结果
修改上面两点后，测试确定性能得到提高，符合预期，问题得到解决。

