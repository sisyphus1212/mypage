# l2fwd 支持 x710 通过 fdir 过滤非分片 ipv4 udp 报文
## 问题描述
需要通过 x710 网卡 fdir 功能过滤非分片 ipv4 udp 报文，直接在网卡硬件上丢弃。

## 解决方案
通过修改 l2fwd 代码来验证，需要注意当开启了 fdir 的时候 hash 功能需要关闭。

### 1. port_conf 的配置，用于 dev_configure
```c
static const struct rte_eth_conf port_conf = {
    .rxmode = {
        .split_hdr_size = 0,
        .header_split   = 0, /**< Header Split disabled */
        .hw_ip_checksum = 0, /**< IP checksum offload disabled */
        .hw_vlan_filter = 0, /**< VLAN filtering disabled */
        .jumbo_frame    = 0, /**< Jumbo Frame Support disabled */
        .hw_strip_crc   = 0, /**< CRC stripped by hardware */
    },
    .txmode = {
        .mq_mode = ETH_MQ_TX_NONE,
    },
    .fdir_conf = {
        .mode = RTE_FDIR_MODE_PERFECT,
        .pballoc = RTE_FDIR_PBALLOC_64K,
        .status = RTE_FDIR_REPORT_STATUS,
        .mask = {
            .vlan_tci_mask = 0x0,
            .ipv4_mask     = {
                .src_ip = 0xFFFFFFFF,
                .dst_ip = 0xFFFFFFFF,
            },
            .ipv6_mask     = {
                .src_ip = {0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF},
                .dst_ip = {0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF},
            },
            .src_port_mask = 0xFFFF,
            .dst_port_mask = 0xFFFF,
            .mac_addr_byte_mask = 0xFF,
            .tunnel_type_mask = 1,
            .tunnel_id_mask = 0xFFFFFFFF,
        },
        .drop_queue = 127,
    },

};
```

### 2. rte_eth_fdir_filter_info 与 rte_eth_fdir_filter 字段填充
```c
    struct rte_eth_fdir_filter_info info;

    memset(&info, 0, sizeof(info));
    info.info_type = RTE_ETH_FDIR_FILTER_INPUT_SET_SELECT;
    info.info.input_set_conf.flow_type = RTE_ETH_FLOW_NONFRAG_IPV4_UDP;
    info.info.input_set_conf.field[0] = RTE_ETH_INPUT_SET_NONE;
    info.info.input_set_conf.inset_size = 0;
    info.info.input_set_conf.op = RTE_ETH_INPUT_SET_SELECT;

    struct rte_eth_fdir_filter arg_udpport = {
        .soft_id = 1,
        .input   = {
            .flow_type = RTE_ETH_FLOW_NONFRAG_IPV4_UDP,
        },
        .action  = {
            .rx_queue  =  0,
            .behavior  = RTE_ETH_FDIR_REJECT,
            .report_status = RTE_ETH_FDIR_REPORT_ID,
        },
    };
```

### 3. 调用 rte_eth_dev_filter_ctrl 完成配置过程
```c
    ret = rte_eth_dev_filter_ctrl(portid, RTE_ETH_FILTER_FDIR, RTE_ETH_FILTER_SET, &info);
    printf("ret is %d\n", ret);
    ret = rte_eth_dev_filter_ctrl(portid, RTE_ETH_FILTER_FDIR,RTE_ETH_FILTER_ADD, &arg_udpport);
    printf("ret is %d\n", ret);
```

### 4. 程序退出前指定 RTE_ETH_FILTER_FLUSH 参数，调用 rte_eth_dev_filter_ctrl 来清空配置！