# x710 hash 分片与非分片 tcp 报文异常问题
## 问题描述
当 rss_hf 中配置了 **ETH_RSS_FRAG_IPV4** 与 **ETH_RSS_NONFRAG_IPV4_TCP** 参数后，一些连接的分片报文会被 hash 到其它队列中，**由于这些分片的报文没有 L4 port number**。

当不配置 **ETH_RSS_NONFRAG_IPV4_TCP** 时，**ETH_RSS_FRAG_IPV4** 哈希函数不会应用到非分片报文上，这些报文将会被投递到队列 0。

## 异常 hash 配置 
 配置内容如下：
 ```c
        #define RSS_X710_KEY_SIZE 52

          static unsigned char tr_rss_key_x710[] = {
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a,
        };
   
        port_conf->rxmode.mq_mode = ETH_MQ_RX_RSS;

        port_conf->rx_adv_conf.rss_conf.rss_key = tr_rss_key_x710;
        port_conf->rx_adv_conf.rss_conf.rss_hf = ETH_RSS_PROTO_MASK;
        port_conf->rx_adv_conf.rss_conf.rss_key_len = RSS_X710_KEY_SIZE;
}
 ```
设置上面的 rss_key，且 rss_hf 配置 **ETH_RSS_PROTO_MASK**，能 hash 到多队列，**不分片报文正常，tcp 分片报文存在问题**。

## 流量配比
**tcp 非分片流，源 ip 与目的 ip 100:100 分布。**

## 测试验证过程
下面的测试过程中，首先打 **100:100 的 tcp 非分片流，能够 hash 到多队列后修改为有分片的 tcp 流，进一步验证。**

**1.使用网卡默认的 rss_key，且修改 rss_hf 为 ETH_RSS_IPV4 | ETH_RSS_IPV6**

测试结果：不能 hash 到多队列。

**2.使用默认的 rss_key 并配置网卡 hash_filter，代码来自 google**

补丁代码如下：

```c
struct rte_eth_conf new_port_conf = {
  .rxmode = {
    .mq_mode = ETH_MQ_RX_RSS,
  },
  .rx_adv_conf = {
    .rss_conf = {
        .rss_hf = ETH_RSS_IP |
              ETH_RSS_TCP |
              ETH_RSS_UDP |
              ETH_RSS_SCTP,
    }
   },
};


#define UINT32_BIT (CHAR_BIT * sizeof(uint32_t))
int sym_hash_enable(int port_id, uint32_t ftype, enum rte_eth_hash_function function)
{
    struct rte_eth_hash_filter_info info;
    int ret = 0;
    uint32_t idx = 0;
    uint32_t offset = 0;

    memset(&info, 0, sizeof(info));

    ret = rte_eth_dev_filter_supported(port_id, RTE_ETH_FILTER_HASH);
    if (ret < 0) {
        printf("RTE_ETH_FILTER_HASH not supported on port: %d",
                         port_id);
        return ret;
    }

    info.info_type = RTE_ETH_HASH_FILTER_GLOBAL_CONFIG;
    info.info.global_conf.hash_func = function;

    idx = ftype / UINT32_BIT;
    offset = ftype % UINT32_BIT;
    info.info.global_conf.valid_bit_mask[idx] |= (1ULL << offset);
    info.info.global_conf.sym_hash_enable_mask[idx] |=
                        (1ULL << offset);

    ret = rte_eth_dev_filter_ctrl(port_id, RTE_ETH_FILTER_HASH,
                                  RTE_ETH_FILTER_SET, &info);
    if (ret < 0)
    {
        printf("Cannot set global hash configurations"
                        "on port %u", port_id);
        return ret;
    }

    return 0;
}

int sym_hash_set(int port_id, int enable)
{
    int ret = 0;
    struct rte_eth_hash_filter_info info;

    memset(&info, 0, sizeof(info));

    ret = rte_eth_dev_filter_supported(port_id, RTE_ETH_FILTER_HASH);
    if (ret < 0) {
        printf("RTE_ETH_FILTER_HASH not supported on port: %d",
                         port_id);
        return ret;
    }

    info.info_type = RTE_ETH_HASH_FILTER_SYM_HASH_ENA_PER_PORT;
    info.info.enable = enable;
    ret = rte_eth_dev_filter_ctrl(port_id, RTE_ETH_FILTER_HASH,
                        RTE_ETH_FILTER_SET, &info);

    if (ret < 0)
    {
        printf("Cannot set symmetric hash enable per port "
                        "on port %u", port_id);
        return ret;
    }

    return 0;
}
```

**dev_configure** 使用 **new_port_conf** 配置，并在 **dev_configure** 前执行如下代码：

```c
                sym_hash_enable(portid, RTE_ETH_FLOW_NONFRAG_IPV4_TCP, RTE_ETH_HASH_FUNCTION_TOEPLITZ);
                sym_hash_enable(portid, RTE_ETH_FLOW_NONFRAG_IPV4_UDP, RTE_ETH_HASH_FUNCTION_TOEPLITZ);
                sym_hash_enable(portid, RTE_ETH_FLOW_FRAG_IPV4, RTE_ETH_HASH_FUNCTION_TOEPLITZ);
                sym_hash_enable(portid, RTE_ETH_FLOW_NONFRAG_IPV4_SCTP, RTE_ETH_HASH_FUNCTION_TOEPLITZ);
                sym_hash_enable(portid, RTE_ETH_FLOW_NONFRAG_IPV4_OTHER, RTE_ETH_HASH_FUNCTION_TOEPLITZ);

                sym_hash_set(portid, 1);
```

测试结果：**能够 hash 开，但是 tcp 分片报文仍旧有问题。**


3.**测试使用 0x6d、0x5a .... 的 rss_key，修改 rss_hf flag 内容为 ETH_RSS_IPV4 | ETH_RSS_IPV6**

测试结果：不能 hash 到多队列。

4.**测试使用默认的 rss_key，并在执行 dev_configure 前添加 filter_ctrl 的补丁代码**

测试结果：能够 hash 到多队列，tcp 分片报文 hash 异常。

**5.测试设置 rss_hf 为 ETH_RSS_IP flag**

```c
        static unsigned char tr_rss_key_x710[] = {
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a,
        };
        
    #define RSS_X710_KEY_SIZE 52

    port_conf->rxmode.mq_mode = ETH_MQ_RX_RSS;
    port_conf->rxmode.max_rx_pkt_len = ETHER_MAX_LEN;
    port_conf->rxmode.split_hdr_size = 0;
    port_conf->rxmode.header_split   = 0; /**< Header Split disabled */
    port_conf->rxmode.hw_ip_checksum = 0; /**< IP checksum offload enabled */
    port_conf->rxmode.hw_vlan_filter = 0; /**< VLAN filtering disabled */
    port_conf->rxmode.hw_vlan_strip  = 0;
    port_conf->rxmode.hw_vlan_extend = 0;
    port_conf->rxmode.jumbo_frame    = 0; /**< Jumbo Frame Support disabled */
    port_conf->rxmode.hw_strip_crc   = 0; /**< CRC stripped by hardware */

    port_conf->txmode.mq_mode = ETH_MQ_TX_NONE;

    port_conf->rx_adv_conf.rss_conf.rss_key = tr_rss_key_x710;
    port_conf->rx_adv_conf.rss_conf.rss_hf = ETH_RSS_IP;
    port_conf->rx_adv_conf.rss_conf.rss_key_len = RSS_X710_KEY_SIZE;
```
测试结果：不能 hash 到多队列。

6.**不设置 rss_key，只设置 rss_hf 为 ETH_RSS_PROTO_MASK** 

测试结果：能够 hash 到多队列，tcp 分片报文 hash 异常。

**7.不设置 rss_key，只设置 rss_hf 为 ETH_RSS_IP** 

测试结果：不能 hash 到多队列。

8.**不设置 rss_key，设置 rss_hf 值如下**：

```c
        ETH_RSS_NONFRAG_IPV4_TCP | \
        ETH_RSS_NONFRAG_IPV4_UDP | \
        ETH_RSS_NONFRAG_IPV4_SCTP | \
        ETH_RSS_L2_PAYLOAD | \
        ETH_RSS_IPV6_TCP_EX
```
测试结果：能够 hash 到多队列，tcp 分片报文 hash 异常。

**9.不设置 rss_key，设置 rss_hf 值如下：**

```c
        ETH_RSS_NONFRAG_IPV4_TCP | \
        ETH_RSS_NONFRAG_IPV4_UDP | \
        ETH_RSS_NONFRAG_IPV4_SCTP)
```
测试结果：能够 hash 到对队列，tcp 分片报文 hash 异常。

10. 不设置 rss_key，设置 rss_hf 值如下： 
```c
ETH_RSS_NONFRAG_IPV4_TCP
```
测试结果：能够 hash 到多对列，tcp 分片报文 hash 异常。

## 根据测试项目得出的初步结论

**只打 tcp 非分片报文的情况下，rss_hf 设定内容必须包含 ETH_RSS_NONFRAG_IPV4_TCP 才能 hash 到多队列！**

## 提问环节
1.真的理解了问题吗？

能够清晰描述问题，没有偏差。

2.收集到的信息中有哪些可参照内容？

**82599 使用对称 rss_key 能够正常工作，不需要额外配置，问题指向 XL710 网卡的特性。**

3.网上有没有相关信息？

**XL710 的 rss hash 存在问题，需要配置 filter_ctrl 来使能一些寄存器**，网上找到的代码测试不能解决问题，**可能存在代码本身问题及使用问题上，需要想方法确认。**

4.是否能够从手册中找到一些蛛丝马迹？

使用手册中的 rss_key 仍旧有问题。

5.手册中提到的 hash key 的有效性需要确认

**待确认**

6.从网上还能否收集到更多的信息？

进一步搜索，找到 [[dpdk-dev] Symmetry for TCP packets on X710 Intel ](https://dev.dpdk.narkive.com/AIj6ALhm/dpdk-dev-symmetry-for-tcp-packets-on-x710-intel) 这个链接。

## 信息扩充环节

dpdk 官方 bugzilla 检索：

结果：无相关内容


## 针对分片报文 hash 字段设定 hash_filter 测试项目

仔细阅读 [[dpdk-dev] Symmetry for TCP packets on X710 Intel ](https://dev.dpdk.narkive.com/AIj6ALhm/dpdk-dev-symmetry-for-tcp-packets-on-x710-intel) 发现与我们遇到的问题非常吻合。

再次回到问题描述上：

>当配置了 ETH_RSS_FRAG_IPV4 与 ETH_RSS_NONFRAG_IPV4_TCP 参数后，一些连接的分片报文会被 hash 到其它队列中，**由于这些分片的报文没有 L4 port number**。

>当你不配置 ETH_RSS_NONFRAG_IPV4_TCP 时，ETH_RSS_FRAG_IPV4 哈希函数不会应用到非分片报文上，这些报文将会被投递到队列 0。

由于我们不能直接控制分片 tcp 报文，可以设定非分片 tcp 报文只使用源与目的 ip 进行 hash，思路清晰明了！

从 [[dpdk-dev] Symmetry for TCP packets on X710 Intel ](https://dev.dpdk.narkive.com/AIj6ALhm/dpdk-dev-symmetry-for-tcp-packets-on-x710-intel)  中摘录并修改代码为如下内容：

```c
        #define UINT64_BIT (CHAR_BIT * sizeof(uint64_t))
        #define RSS_X710_KEY_SIZE 52

        static unsigned char tr_rss_key_x710[] = {
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a, 0x6d, 0x5a,
            0x6d, 0x5a, 0x6d, 0x5a,
        };
        
        
        port_conf->rxmode.mq_mode = ETH_MQ_RX_RSS;
        port_conf->rx_adv_conf.rss_conf.rss_key = tr_rss_key_x710;
        port_conf->rx_adv_conf.rss_conf.rss_key_len = RSS_X710_KEY_SIZE;
        port_conf.rx_adv_conf.rss_conf.rss_hf = ETH_RSS_IPV4 	| 				ETH_RSS_FRAG_IPV4
| ETH_RSS_NONFRAG_IPV4_TCP | ETH_RSS_NONFRAG_IPV4_UDP |
ETH_RSS_NONFRAG_IPV4_SCTP | ETH_RSS_NONFRAG_IPV4_OTHER | ETH_RSS_IPV6 |
ETH_RSS_FRAG_IPV6 | ETH_RSS_NONFRAG_IPV6_TCP | ETH_RSS_NONFRAG_IPV6_UDP
| ETH_RSS_NONFRAG_IPV6_SCTP | ETH_RSS_NONFRAG_IPV6_OTHER;
        
        struct rte_eth_hash_filter_info hinfo;
        uint32_t idx = 0;
        uint32_t offset = 0;
        uint32_t ftype;

        // specific commands for X710
        // select per ipv4 tcp - src ipv4
        memset(&hinfo, 0, sizeof (hinfo));
        hinfo.info_type = RTE_ETH_HASH_FILTER_INPUT_SET_SELECT;
        hinfo.info.input_set_conf.flow_type = RTE_ETH_FLOW_NONFRAG_IPV4_TCP;
        hinfo.info.input_set_conf.field[0] = RTE_ETH_INPUT_SET_L3_SRC_IP4;
        hinfo.info.input_set_conf.inset_size = 1;
        hinfo.info.input_set_conf.op = RTE_ETH_INPUT_SET_SELECT;
        ret = rte_eth_dev_filter_ctrl(portid, RTE_ETH_FILTER_HASH,
                                RTE_ETH_FILTER_SET, &hinfo);
        if (ret < 0)
        {
                printf("Failure: set select ipv4 tcp (src ipv4) for port %hhu\n", portid);
        }

        // add per ipv4 tcp - dst ipv4
        memset(&hinfo, 0, sizeof (hinfo));
        hinfo.info_type = RTE_ETH_HASH_FILTER_INPUT_SET_SELECT;
        hinfo.info.input_set_conf.flow_type = RTE_ETH_FLOW_NONFRAG_IPV4_TCP;
        hinfo.info.input_set_conf.field[0] = RTE_ETH_INPUT_SET_L3_DST_IP4;
        hinfo.info.input_set_conf.inset_size = 1;
        hinfo.info.input_set_conf.op = RTE_ETH_INPUT_SET_ADD;
        ret = rte_eth_dev_filter_ctrl(portid, RTE_ETH_FILTER_HASH,
                    RTE_ETH_FILTER_SET, &hinfo);
        if (ret < 0)
        {
            printf("Failure: set add ipv4 tcp (dst ipv4) for port %hhu\n", portid);
        }

        // hash global config ipv4 tcp
        memset(&hinfo, 0, sizeof (hinfo));
        hinfo.info_type = RTE_ETH_HASH_FILTER_GLOBAL_CONFIG;
        hinfo.info.global_conf.hash_func = RTE_ETH_HASH_FUNCTION_DEFAULT;
        ftype = RTE_ETH_FLOW_NONFRAG_IPV4_TCP;
        idx = ftype / UINT64_BIT;
        offset = ftype % UINT64_BIT;
        hinfo.info.global_conf.valid_bit_mask[idx] |= (1ULL << offset);
        hinfo.info.global_conf.sym_hash_enable_mask[idx] |= (1ULL << offset);
        ret = rte_eth_dev_filter_ctrl(portid, RTE_ETH_FILTER_HASH,
                RTE_ETH_FILTER_SET, &hinfo);
        if (ret < 0)
        {
            printf("Cannot set global hash configurations for port %hhu protoipv4 tcp\n", portid);
        }
```

上述代码中 filter_ctrl 设定代码放到 tx 与 rx queue setup 之后执行，**测试确认 ipv4 tcp 分片报文正常 hash!**

对于 ipv6 tcp 分片报文 hash，可以参照上述过程配置 RTE_ETH_FLOW_NONFRAG_IPV6_TCP flow type，实测有效！