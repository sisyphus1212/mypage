# dpdk 收发包函数分析：dpdk-20.11 ice sse 向量收发包函数关键过程分析

## 收包函数主体逻辑
### mbuf_initializer 字段用于初始化每个 mbuf
mbuf_initializer 字段初始化的内容：

```c
	/* next 8 bytes are initialised on RX descriptor rearm */
	RTE_MARKER64 rearm_data;
	uint16_t data_off;

	/**
	 * Reference counter. Its size should at least equal to the size
	 * of port field (16 bits), to support zero-copy broadcast.
	 * It should only be accessed using the following functions:
	 * rte_mbuf_refcnt_update(), rte_mbuf_refcnt_read(), and
	 * rte_mbuf_refcnt_set(). The functionality of these functions (atomic,
	 * or non-atomic) is controlled by the RTE_MBUF_REFCNT_ATOMIC flag.
	 */
	uint16_t refcnt;
	uint16_t nb_segs;         /**< Number of segments. */

	/** Input port (16 bits to support more than 256 virtual ports).
	 * The event eth Tx adapter uses this field to specify the output port.
	 */
	uint16_t port;
```

这部分值每个报文基本一致。

**mbuf_initialized 结构的内容：**

```c
    mbuf_initialized ----->----------------------
                      16b | data_off             | RTE_PKTMBUF_HEADROOM
                      16b | refcnt               | 1
                      16b | nb_segs              | 1
                      16b | port_id              | rxq->port_id

```

向量函数含义：

```c
__m128i _mm_set_epi64x(__int64 q1, __int64 q0);
设置两个 64 bit 整型值
result = [ q0 , q1 ]
```

初始化 mbuf_init 结构：

```c
const __m128i mbuf_init = _mm_set_epi64x(0, rxq->mbuf_initializer);
```

执行后 mbuf_init 的值 :

```c
    mbuf_init  ----------->------------------------
                      16b | data_off             | RTE_PKTMBUF_HEADROOM
                      16b | refcnt               | 1
                      16b | nb_segs              | 1
                      16b | port_id              | rxq->port_id
                      32b | 0                    |
                      32b | 0                    |

```

### 1. 设置 crc 掩码的值，对一个 mbuf 进行处理，同时将 pkt_len 与 data_len 减去 crc_len 长度

向量函数含义：

```c
__m128i _mm_set_epi16(short w7, short w6, short w5, short w4, short w3, short w2, short
w1, short w0);

设置 8 个有符号 16bit 整型
result = [ w0 , w1 , … , w7 ]
```

驱动掩码设置相关代码：

```c
	__m128i crc_adjust = _mm_set_epi16
				(0, 0, 0,       /* ignore non-length fields */
				 -rxq->crc_len, /* sub crc on data_len */
				 0,          /* ignore high-16bits of pkt_len */
				 -rxq->crc_len, /* sub crc on pkt_len */
				 0, 0           /* ignore pkt_type field */
				);

```
此处的掩码设置用于后续基于向量单位对多个报文同时计算。

### 2. 设置后续运行的掩码
mbuf 中相关的字段结构：

| 变量名称   | 变量宽度 |
| ---------- | -------- |
| pkt_type   | 32       |
| pkt_len    | 64       |
| data_len   | 80       |
| vlan_macip | 96       |
| rss_hash   | 128      |

向量函数代码：
```c
	const __m128i zero = _mm_setzero_si128();
	/* mask to shuffle from desc. to mbuf */
	const __m128i shuf_msk = _mm_set_epi8
			(0xFF, 0xFF,
			 0xFF, 0xFF,  /* rss hash parsed separately */
			 11, 10,      /* octet 10~11, 16 bits vlan_macip */
			 5, 4,        /* octet 4~5, 16 bits data_len */
			 0xFF, 0xFF,  /* skip high 16 bits pkt_len, zero out */
			 5, 4,        /* octet 4~5, low 16 bits pkt_len */
			 0xFF, 0xFF,  /* pkt_type set as unknown */
			 0xFF, 0xFF   /* pkt_type set as unknown */
			);
```

**0xFF 表示将对应字节的值清 0，最高位不为 1 表示选择 a[n & 0xf] 字节值。**
此掩码**跳过 pkt_len 的高 16-bit**。

### 3. 设置 EOP 掩码值、dd mask、eop mask
```c
	const __m128i eop_shuf_mask = _mm_set_epi8(0xFF, 0xFF,
						   0xFF, 0xFF,
						   0xFF, 0xFF,
						   0xFF, 0xFF,
						   0xFF, 0xFF,
						   0xFF, 0xFF,
						   0x04, 0x0C,
						   0x00, 0x08);

	/**
	 * compile-time check the above crc_adjust layout is correct.
	 * NOTE: the first field (lowest address) is given last in set_epi16
	 * call above.
	 */
	RTE_BUILD_BUG_ON(offsetof(struct rte_mbuf, pkt_len) !=
			 offsetof(struct rte_mbuf, rx_descriptor_fields1) + 4);
	RTE_BUILD_BUG_ON(offsetof(struct rte_mbuf, data_len) !=
			 offsetof(struct rte_mbuf, rx_descriptor_fields1) + 8);

	/* 4 packets DD mask */
	const __m128i dd_check = _mm_set_epi64x(0x0000000100000001LL,
						0x0000000100000001LL);
	/* 4 packets EOP mask */
	const __m128i eop_check = _mm_set_epi64x(0x0000000200000002LL,
						 0x0000000200000002LL);

```

**dd_check 与 eop_check 针对 rx 描述符，同时对两个描述符进行操作，每个描述符占据 64-bit**。

### 4. 判断是否需要重整队列，需要则执行队列重整操作

申请 **ICE_RXQ_REARM_THRESH** 个 mbuf，然后将 **mbuf dataroom 的物理地址填充到空闲的描述符中。**

### 5. 获取当前软件可用描述符并预取描述符

**普通函数逻辑，读取描述符中的标志，当没有可用描述符时，函数直接返回。**

### 6. 填充 mbuf dataroom 物理地址到描述符**函数主体向量指令**

向量函数代码：

```c
	/* Initialize the mbufs in vector, process 2 mbufs in one loop */
	for (i = 0; i < ICE_RXQ_REARM_THRESH; i += 2, rxep += 2) {
		__m128i vaddr0, vaddr1;

		mb0 = rxep[0].mbuf;
		mb1 = rxep[1].mbuf;

		/* load buf_addr(lo 64bit) and buf_iova(hi 64bit) */
		RTE_BUILD_BUG_ON(offsetof(struct rte_mbuf, buf_iova) !=
				 offsetof(struct rte_mbuf, buf_addr) + 8);
		vaddr0 = _mm_loadu_si128((__m128i *)&mb0->buf_addr);
		vaddr1 = _mm_loadu_si128((__m128i *)&mb1->buf_addr);

		/* convert pa to dma_addr hdr/data */
		dma_addr0 = _mm_unpackhi_epi64(vaddr0, vaddr0);
		dma_addr1 = _mm_unpackhi_epi64(vaddr1, vaddr1);

		/* add headroom to pa values */
		dma_addr0 = _mm_add_epi64(dma_addr0, hdr_room);
		dma_addr1 = _mm_add_epi64(dma_addr1, hdr_room);

		/* flush desc with pa dma_addr */
		_mm_store_si128((__m128i *)&rxdp++->read, dma_addr0);
		_mm_store_si128((__m128i *)&rxdp++->read, dma_addr1);
	}

```

mbuf 中虚拟地址与物理地址结构如下：

```c
typedef uint64_t rte_iova_t;
.........

	void *buf_addr;           /**< Virtual address of segment buffer. */
	/**
	 * Physical address of segment buffer.
	 * Force alignment to 8-bytes, so as to ensure we have the exact
	 * same mbuf cacheline0 layout for 32-bit and 64-bit. This makes
	 * working on vector drivers easier.
	 */
	rte_iova_t buf_iova __rte_aligned(sizeof(rte_iova_t));

```

使用 **128-bit** 寄存器，一次将 **buf_addr 与 buf_iova 地址加载到一个 128-bit 的变量中**，**低 64-bit 存储 buf_addr，高 64-bit 存储 buf_iova 地址**。

6.1 **每次处理两个 rxd，首先将第一组 rxep mbuf 地址分别加载到 mb0 与 mb1 两个 mbuf 结构中**

6.2 **将 mb0 的虚拟地址加载到 vaddr0 128-bit 中，将 mb1 的虚拟地址加载到 vaddr1 128-bit 中**

**处理后 vaddr0 与 vaddr1 内容示例：**

```c
        vaddr0 -->------------------      vaddr1 ---->---------------
        hi-64b -->|  mb0->buf_iova |     hi-64b  --->| mb1->buf_iova|
        lo-64b -->|  mb0->buf_addr |     lo-64b  --->| mb1->buf_addr|
                  ------------------                 ----------------

```

6.3 **调整 vaddr0、vaddr1 中 buf_iova 的位置**

向量函数代码：

```c
		/* convert pa to dma_addr hdr/data */
		dma_addr0 = _mm_unpackhi_epi64(vaddr0, vaddr0);
		dma_addr1 = _mm_unpackhi_epi64(vaddr1, vaddr1);
```

执行后 vaddr0 与 vaddr1 结构：

```c
        dma_addr0 -->-----------------     dma_addr1 ----->----------------
        hi-64b   -->|  mb0->buf_iova |     hi-64b     --->| mb1->buf_iova |
        lo-64b   -->|  mb0->buf_iova |     lo-64b     --->| mb1->buf_iova |
                  ------------------                      ----------------
```

**6.4 使用 dma_addr0 加上 hdr_room 将地址指向 dataroom 的物理地址**

向量函数代码：

```c
	/* add headroom to pa values */
	dma_addr0 = _mm_add_epi64(dma_addr0, hdr_room);
	dma_addr1 = _mm_add_epi64(dma_addr1, hdr_room);
```

执行上述操作后的值：
```c
    dma_addr0 -->----------------------------        dma_addr-->---------------------------
    hi-64b   -->|  mb0->buf_iova + hdr_room |      hi-64b   --->| mb1->buf_iova + hdr_room |
    lo-64b   -->|  mb0->buf_iova + hdr_room |      lo-64b   --->| mb1->buf_iova + hdr_room |
              -------------------------------                   ----------------------------
```

**6.5 将 dma_addr 存储到描述符中**

```c
		/* flush desc with pa dma_addr */
		_mm_store_si128((__m128i *)&rxdp++->read, dma_addr0);
		_mm_store_si128((__m128i *)&rxdp++->read, dma_addr1);
```
rx_desc 中报文地址相关定义：
```c
		__le64 pkt_addr; /* Packet buffer address */
		__le64 hdr_addr; /* Header buffer address */
```
普通收包函数中设置内容：
```c
		/**
		 * fill the read format of descriptor with physic address in
		 * new allocated mbuf: nmb
		 */
		rxdp->read.hdr_addr = 0;
		rxdp->read.pkt_addr = dma_addr;
```

普通收包函数中 **hdr_addr 设置为 0，sse 中却设定为了 dma_addr，这里有机关！**

**6.6 更新软件变量值**

### 7. 判断当前描述符的 dd 位是否为 1，为 1 表示至少有一个报文

### 8. 开始批量从 rx desc 向 mbuf 转换

**转换前添加如下断言，确保 mbuf 中字段的偏移正确。**

```c
	/**
	 * Compile-time verify the shuffle mask
	 * NOTE: some field positions already verified above, but duplicated
	 * here for completeness in case of future modifications.
	 */
	RTE_BUILD_BUG_ON(offsetof(struct rte_mbuf, pkt_len) !=
			 offsetof(struct rte_mbuf, rx_descriptor_fields1) + 4);
	RTE_BUILD_BUG_ON(offsetof(struct rte_mbuf, data_len) !=
			 offsetof(struct rte_mbuf, rx_descriptor_fields1) + 8);
	RTE_BUILD_BUG_ON(offsetof(struct rte_mbuf, vlan_tci) !=
			 offsetof(struct rte_mbuf, rx_descriptor_fields1) + 10);
	RTE_BUILD_BUG_ON(offsetof(struct rte_mbuf, hash) !=
			 offsetof(struct rte_mbuf, rx_descriptor_fields1) + 12);
```

## **使用向量指令从描述符转化为 mbuf 的关键过程**
**1. 进入 for 循环，每次处理 4 个描述符，填充 4 个 mbuf（此处假定为这种情况）**
**2. 加载描述符中的 mbuf 与描述符内容到 128-bit 变量中**

**一个 128-bit 加载两个 mbuf 地址**：

```c
     mbp1 ---->-------------------------
     hi-64    | sw_ring[pos + 1]->mbuf |
     lo-64    | sw_ring[pos]->mbuf     |
               -------------------------

     mbp2 ---->-------------------------
     hi-64    | sw_ring[pos + 2]->mbuf |
     lo-64    | sw_ring[pos + 3]->mbuf |
              --------------------------

```

加载四个描述符到四个 128-bit 的 desc 变量中：

```c
		descs[3] = _mm_loadu_si128((__m128i *)(rxdp + 3));
		rte_compiler_barrier();

		/* B.2 copy 2 64 bit or 4 32 bit mbuf point into rx_pkts */
		_mm_storeu_si128((__m128i *)&rx_pkts[pos], mbp1);

		descs[2] = _mm_loadu_si128((__m128i *)(rxdp + 2));
		rte_compiler_barrier();
		/* B.1 load 2 mbuf point */
		descs[1] = _mm_loadu_si128((__m128i *)(rxdp + 1));
		rte_compiler_barrier();
		descs[0] = _mm_loadu_si128((__m128i *)(rxdp));

```

在每个 desc 加载时都添加了**编译屏障，避免优化产生问题**，加载后 desc 结构：

```c
desc[0]  --> rxdp[0]
desc[1]  --> rxdp[1]
desc[2]  --> rxdp[2]
desc[3]  --> rxdp[3]

```
接收描述符定义：

```c
union ice_32b_rx_flex_desc {
	struct {
		__le64 pkt_addr; /* Packet buffer address */
		__le64 hdr_addr; /* Header buffer address */
				 /* bit 0 of hdr_addr is DD bit */
		__le64 rsvd1;
		__le64 rsvd2;
	} read;
	struct {
		/* Qword 0 */
		u8 rxdid; /* descriptor builder profile ID */
		u8 mir_id_umb_cast; /* mirror=[5:0], umb=[7:6] */
		__le16 ptype_flex_flags0; /* ptype=[9:0], ff0=[15:10] */
		__le16 pkt_len; /* [15:14] are reserved */
		__le16 hdr_len_sph_flex_flags1; /* header=[10:0] */
						/* sph=[11:11] */
						/* ff1/ext=[15:12] */

		/* Qword 1 */
		__le16 status_error0;
		__le16 l2tag1;
		__le16 flex_meta0;
		__le16 flex_meta1;

		/* Qword 2 */
		__le16 status_error1;
		u8 flex_flags2;
		u8 time_stamp_low;
		__le16 l2tag2_1st;
		__le16 l2tag2_2nd;

		/* Qword 3 */
		__le16 flex_meta2;
		__le16 flex_meta3;
		union {
			struct {
				__le16 flex_meta4;
				__le16 flex_meta5;
			} flex;
			__le32 ts_high;
		} flex_ts;
	} wb; /* writeback */
};

```

单个 desc 加载后内容如下：

```c
 Qword 1   hi-64
 Qword 0   lo-64
```

**注意顺序为从高地址向低地址加载**。

**3. 将 mbuf 地址填充到 rx_pkts 数组中**

```c

	/* B.2 copy 2 64 bit or 4 32 bit mbuf point into rx_pkts */
	_mm_storeu_si128((__m128i *)&rx_pkts[pos], mbp1);

	/* B.2 copy 2 mbuf point into rx_pkts  */
	_mm_storeu_si128((__m128i *)&rx_pkts[pos + 2], mbp2);

```

**4. 当设置了 split_packet 后，预取 mbuf 中的第二个 cache line**

   在 mbuf 结构中使用不占空间的变量标识每一个 cache line 的起始位置。

**5. 将 desc 中的字段填充到 pktmbuf 中**

向量函数代码：
```c
		/* D.1 pkt 3,4 convert format from desc to pktmbuf */
		pkt_mb3 = _mm_shuffle_epi8(descs[3], shuf_msk);
		pkt_mb2 = _mm_shuffle_epi8(descs[2], shuf_msk);

		/* D.1 pkt 1,2 convert format from desc to pktmbuf */
		pkt_mb1 = _mm_shuffle_epi8(descs[1], shuf_msk);
		pkt_mb0 = _mm_shuffle_epi8(descs[0], shuf_msk);

		/* C.1 4=>2 filter staterr info only */
		sterr_tmp2 = _mm_unpackhi_epi32(descs[3], descs[2]);
		/* C.1 4=>2 filter staterr info only */
		sterr_tmp1 = _mm_unpackhi_epi32(descs[1], descs[0]);

```
掩码值：
```c
	const __m128i shuf_msk = _mm_set_epi8
			(0xFF, 0xFF,
			 0xFF, 0xFF,  /* rss hash parsed separately */
			 11, 10,      /* octet 10~11, 16 bits vlan_macip */
			 5, 4,        /* octet 4~5, 16 bits data_len */
			 0xFF, 0xFF,  /* skip high 16 bits pkt_len, zero out */
			 5, 4,        /* octet 4~5, low 16 bits pkt_len */
			 0xFF, 0xFF,  /* pkt_type set as unknown */
			 0xFF, 0xFF   /* pkt_type set as unknown */
			);

```
rx 描述符与 mbuf 中的相关字段定义摘录：
```c
		/* Qword 0 */
		u8 rxdid; /* descriptor builder profile ID */
		u8 mir_id_umb_cast; /* mirror=[5:0], umb=[7:6] */
		__le16 ptype_flex_flags0; /* ptype=[9:0], ff0=[15:10] */
		__le16 pkt_len; /* [15:14] are reserved */
		__le16 hdr_len_sph_flex_flags1; /* header=[10:0] */
						/* sph=[11:11] */
						/* ff1/ext=[15:12] */

		/* Qword 1 */
		__le16 status_error0;
		__le16 l2tag1;
		__le16 flex_meta0;
		__le16 flex_meta1;

```
```c
union {
	uint32_t packet_type; /**< L2/L3/L4 and tunnel information.
	...................
};

uint32_t pkt_len;         /**< Total pkt len: sum of all segments. */
uint16_t data_len;        /**< Amount of data in segment buffer. */
/** VLAN TCI (CPU order), valid if PKT_RX_VLAN is set. */
uint16_t vlan_tci;

union {
	union {
		uint32_t rss;     /**< RSS hash result if RSS enabled */

```

执行 **__mm_shuffle_epi8** 函数，设置 **pkt_len、data_len、vlan_tci，清空 packet_type、rss**。

向量函数调用代码：
```c
pkt_mb3 = _mm_shuffle_epi8(descs[3], shuf_msk);
```

调用之后 pkt_mb3 的结构内容如下：
```c
pkt_mb3 ---->-------------------------------------------
            | 0                       |
            ---------------------------
            | 0                       |   mbuf->packet_type
            ---------------------------
            | 0                       |
            ---------------------------
            | 0                       |
            ---------------------------------------------
            |  desc[3].pkt_len low 8b |
            ---------------------------
            |  desc[3].pkt_len high 8b|
            ---------------------------   mbuf->pkt_len
            | 0                       |
            ---------------------------
            | 0                       |
            ----------------------------------------------
            | desc[3].pkt_len low 8b  |
            ---------------------------   mbuf->data_len
            | desc[3].pkt_len hith 8b |
            ----------------------------------------------
            | desc[3].l2tag1 low 8b   |
            ---------------------------   mbuf->vlan_tci
            | desc[3].l2tag1 low 8b   |
            -----------------------------------------------
            | 0                       |
            ---------------------------
            | 0                       |   mbuf->rss
            ---------------------------
            | 0                       |
            ---------------------------
            | 0                       |
            -----------------------------------------------

```

**pkt_mb2、pkt_mb1、pkt_mb0 结构类似**。

**6. 过滤 staterr 信息**

**向量函数代码：**
```c
		/* C.1 4=>2 filter staterr info only */
		sterr_tmp2 = _mm_unpackhi_epi32(descs[3], descs[2]);
		/* C.1 4=>2 filter staterr info only */
		sterr_tmp1 = _mm_unpackhi_epi32(descs[1], descs[0]);

```
向量函数含义：
```c
__m128i _mm_unpackhi_epi32(__m128i a, __m128i b);
交替高2位有符号或无符号32bit整数
result = [ a2 , b2 , a3, b3 ]

```
rx desc 中相关结构：
```c
		/* Qword 0 */
		u8 rxdid; /* descriptor builder profile ID */
		u8 mir_id_umb_cast; /* mirror=[5:0], umb=[7:6] */
		__le16 ptype_flex_flags0; /* ptype=[9:0], ff0=[15:10] */
		__le16 pkt_len; /* [15:14] are reserved */
		__le16 hdr_len_sph_flex_flags1; /* header=[10:0] */
						/* sph=[11:11] */
						/* ff1/ext=[15:12] */

		/* Qword 1 */
		__le16 status_error0;
		__le16 l2tag1;
		__le16 flex_meta0;
		__le16 flex_meta1;

```
执行后 sterr_tmp2 结构如下：

```c
     sterr_tmp2 ---->-----------------------------------
                     | desc[3].l2tag1 + status_error0  |
                     | desc[2].l2tag1 + status_error0  |
                     | desc[3].flex_meta0 + flex_meta1 |
                     | desc[2].flex_meta0 + flex_meta1 |
                     -----------------------------------

```

**7. 将 rx olflags 映射到 mbuf 中**

## 将四个描述符合并为一个的向量函数逻辑分析
ice_rx_desc 部分定义：
```c
	struct {
		/* Qword 0 */
		u8 rxdid; /* descriptor builder profile ID */
		u8 mir_id_umb_cast; /* mirror=[5:0], umb=[7:6] */
		__le16 ptype_flex_flags0; /* ptype=[9:0], ff0=[15:10] */
		__le16 pkt_len; /* [15:14] are reserved */
		__le16 hdr_len_sph_flex_flags1; /* header=[10:0] */
						/* sph=[11:11] */
						/* ff1/ext=[15:12] */

		/* Qword 1 */
		__le16 status_error0;
		__le16 l2tag1;
		__le16 flex_meta0;
		__le16 flex_meta1;

		/* Qword 2 */
		__le16 status_error1;
		u8 flex_flags2;
		u8 time_stamp_low;
		__le16 l2tag2_1st;
		__le16 l2tag2_2nd;

		/* Qword 3 */
		__le16 flex_meta2;
		__le16 flex_meta3;
```
合并 4 个描述符标志信息的向量函数调用代码：
```c
	/* merge 4 descriptors */
	flags = _mm_unpackhi_epi32(descs[0], descs[1]);
	tmp_desc = _mm_unpackhi_epi32(descs[2], descs[3]);
	tmp_desc = _mm_unpacklo_epi64(flags, tmp_desc);
	tmp_desc = _mm_and_si128(tmp_desc, desc_mask);

```

第一步执行后 flags 的布局:
```c
   flags ----------->---------------------------------
                    |  desc[0].status_error0 l2tag1  |
                    |  desc[1].status_error0 l2tag1  |
                    |  desc[0].flex_meta0 flex_meta1 |
                    |  desc[1].flex_meta0 flex_meta1 |

```

第二步执行后 tmp_desc 的布局:

```c
   tmp_desc -------->---------------------------------
                    |  desc[2].status_error0 l2tag1  |
                    |  desc[3].status_error0 l2tag1  |
                    |  desc[2].flex_meta0 flex_meta1 |
                    |  desc[3].flex_meta0 flex_meta1 |

```

第三步执行后 tmp_desc 的布局:

```c
   tmp_desc -------->---------------------------------
                    | desc[0].status_error0 l2tag1  |
                    | desc[1].status_error0 l2tag1  |
                    | desc[2].status_error0 l2tag1  |
                    | desc[3].status_error0 l2tag1  |
```

desc_mask 内容：

```c
	/* mask everything except checksum, RSS and VLAN flags.
	 * bit6:4 for checksum.
	 * bit12 for RSS indication.
	 * bit13 for VLAN indication.
	 */
	const __m128i desc_mask = _mm_set_epi32(0x3070, 0x3070,
						0x3070, 0x3070);
```

**合并操作后，设置四个描述符中 checksum、rss、vlan 的值。**

## 发包函数实现分析

tx 的逻辑非常简单，要用 mbuf 中的字段填充一个 ice_tx_desc 结构，使用到的 sse 向量函数逻辑：

```c
static inline void
ice_vtx1(volatile struct ice_tx_desc *txdp,
	 struct rte_mbuf *pkt, uint64_t flags)
{
	uint64_t high_qw =
		(ICE_TX_DESC_DTYPE_DATA |
		 ((uint64_t)flags  << ICE_TXD_QW1_CMD_S) |
		 ((uint64_t)pkt->data_len << ICE_TXD_QW1_TX_BUF_SZ_S));

	__m128i descriptor = _mm_set_epi64x(high_qw,
				pkt->buf_iova + pkt->data_off);
	_mm_store_si128((__m128i *)txdp, descriptor);
}
```

ice_tx_desc 结构：

```c
/* Tx Descriptor */
struct ice_tx_desc {
        __le64 buf_addr; /* Address of descriptor's data buf */
        __le64 cmd_type_offset_bsz;
};
```

发包函数需要填充 **mbuf dataroom 起始地址的物理地址以及一些发送标志到发送描述符中**，ice_tx_desc 为 128bit，填充一次就能够存储这两个字段。

# 总结
dpdk 内部向量收发包函数使用**硬件向量指令**优化传统的收发包过程，主要的优化内容集中在**收包逻辑上**，发包的主要过程为 dma 操作，优化空间非常有限。

dpdk 收发包 burst 过程是一个非常代表性的批量化处理场景，将**硬件向量指令集成到批量化上**，带来了**小包性能的显著提升**以及程序 cpu 占用率的下降，是**挖掘硬件特性**达成性能优化的一个很好的案例。

同时需要说明的是 dpdk 使用向量收发包函数**需要满足一定的条件**，这个条件因**网卡不同**而有所区别，这些条件包括了 dpdk 接口初始化时配置的一些硬件卸载功能，需要非常注意！

**备注：dpdk 内部不直接使用向量指令而是通过使用一层封装函数来间接调用！**
