# dpdk 问题分析：dpdk 程序不收包问题案例
## 问题描述
某设备运行 dpdk-16.04 版本程序，绑定的网卡中，某 igb 网卡出现一个口不能收包的情况。

## 排查过程
### 1. 确定问题
此问题是测试同学反馈的，第一步需要做的是确定问题。在这一步需要确定如下几点：

1. 对端是否在发包
2. ethtoool -S 多次获取统计信息是否能够说明接口不收包
3. 接口是否处于 up 状态
4. 其它口是否有类似的问题
5. dmesg 中是否有异常告警
6. 配置文件是否正确
7. 程序是否有段错误

这一步的排查相对简单，但是需要对**异常信息**敏感，对获取的信息都进行记录，在这一步中找不到问题则继续向下排查。

### 2. 扩大输入信息
第一步的排查没有找到问题能够说明程序运行的基础环境是正常的，在此基础上我们需要**扩大输入信息**来找到新的【疑点】。

一般来说会收集如下信息：

1. ethtool 确定接口状态
2. ethtool -i 确定接口类型
3. ethtool -d dump 接口寄存器信息
4. ethtool -e dump eeprom 信息

这些信息反映了出问题接口的不同状态，这些信息不能直接看出问题。一般还需要找一个型号相同且正常工作的网卡接口来获取相同的信息进行对比。我们可以预先将正常工作的网卡信息 dump 出来存放到本地，为定位问题创造【基线数据】。

可以使用 beyond compare 来将异常接口的信息与正常接口信息对比，对差异的内容进行分析，找到怀疑点，如果你不清楚上述信息中不同字段的含义，那就对所有的差异进行分析。

dump 出的寄存器的对比信息需要参考网卡的数据手册，同样可以预先下载公司使用的网卡手册到本地。

这一步旨在扩大输入信息，这些信息为后续的排查提供【数据参考】。

### 3. 确定接口
在进一步执行前，需要确定异常接口的网卡型号、pci 号、dpdk 程序中对应的 port_id。

执行 ethtool -i xxx 确定网卡型号与 pci 号，ethtool -i 能够确定 pci 号，获取到这个 pci 号之后再结合 lspci 就能够确定网卡的型号。

ethtool -i 执行示例如下：
```bash
# ethtool -i xxx
driver: igb
.........
bus-info: 0000:11:00.1
supports-statistics: yes
supports-test: yes
supports-eeprom-access: yes
supports-register-dump: yes
supports-priv-flags: no
```
lspci 输出信息过滤如下：

```bash
11:00.0 Ethernet controller: Intel Corporation I350 Gigabit Network Connection (rev 01)
11:00.1 Ethernet controller: Intel Corporation I350 Gigabit Network Connection (rev 01)
11:00.2 Ethernet controller: Intel Corporation I350 Gigabit Network Connection (rev 01)
11:00.3 Ethernet controller: Intel Corporation I350 Gigabit Network Connection (rev 01)
```
从上面的示例可以看出异常接口的 pci 号为 **11:00.1**，对应的网卡型号为 **I350**。

dpdk 程序运行时也会分配一个 **port_id**，**port_id** 在 dpdk 程序中标识每个单独的网口，这个 **port_id** 可以通过查看程序的启动信息、产品的配置文件内容来确定。

### 4.  在问题环境中调试
dpdk 支持多进程通信，有 primary 与 secondary 进程，proc_info 是一个 secondary 进程，能够用来查看一些与 primary 进程共享的内存信息。对 dpdk 程序的调试的特别之处在于可以**使用 proc_info** 进行调试。

首先需要**确定程序使用的 dpdk 版本**，编译**带调试信息的 proc_info 程序**来 **dump** 关键的信息并查看。

这一步需要用到上面确定的 dpdk 程序的 port_id，在这个问题里 port_id 值为 11，这个 11 是 rte_eth_devices 数组的下标，在 dpdk 程序中**唯一标识一个接口。**

#### 调试信息记录
##### rte_eth_devices 信息
出问题的口：

```gdb
(gdb) print rte_eth_devices[11]
$4 = {rx_pkt_burst = 0x54bd44 <eth_igb_recv_scattered_pkts>, tx_pkt_burst = 0x54a7a0 <eth_igb_xmit_pkts>,
  data = 0x513ffb0280, driver = 0x5f69a0 <rte_igb_pmd>, dev_ops = 0x5ca588 <eth_igb_ops>,
  pci_dev = 0x90d460, link_intr_cbs = {tqh_first = 0x0, tqh_last = 0x8188c0 <rte_eth_devices+181064>},
  post_rx_burst_cbs = {0x0 <repeats 1024 times>}, pre_tx_burst_cbs = {0x0 <repeats 1024 times>},
  attached = 1 '\001', dev_type = RTE_ETH_DEV_PCI}
```
对照口：
```gdb
(gdb) print rte_eth_devices[12]
$5 = {rx_pkt_burst = 0x54bd44 <eth_igb_recv_scattered_pkts>, tx_pkt_burst = 0x54a7a0 <eth_igb_xmit_pkts>,
  data = 0x513ffb1a40, driver = 0x5f69a0 <rte_igb_pmd>, dev_ops = 0x5ca588 <eth_igb_ops>,
  pci_dev = 0x90dbe0, link_intr_cbs = {tqh_first = 0x0, tqh_last = 0x81c908 <rte_eth_devices+197520>},
  post_rx_burst_cbs = {0x0 <repeats 1024 times>}, pre_tx_burst_cbs = {0x0 <repeats 1024 times>},
  attached = 1 '\001', dev_type = RTE_ETH_DEV_PCI}
(gdb)
```
对比确定收发包函数正常，其它字段没有怀疑点。
##### rte_eth_dev_data 信息
出问题的口：

```gdb
(gdb) print *rte_eth_devices[11]->data
$7 = {name = "17:0.1", '\000' <repeats 25 times>, rx_queues = 0x513fead9c0, tx_queues = 0x513fead940,
  nb_rx_queues = 6, nb_tx_queues = 6, sriov = {active = 0 '\000', nb_q_per_pool = 0 '\000',
    def_vmdq_idx = 0, def_pool_q_idx = 0}, dev_private = 0x513fe20b80, dev_link = {link_speed = 1000,
    link_duplex = 1, link_autoneg = 1, link_status = 1}, dev_conf = {link_speeds = 0, rxmode = {
      mq_mode = ETH_MQ_RX_RSS, max_rx_pkt_len = 2048, split_hdr_size = 0, header_split = 0,
      hw_ip_checksum = 1, hw_vlan_filter = 0, hw_vlan_strip = 0, hw_vlan_extend = 0, jumbo_frame = 1,
      hw_strip_crc = 0, enable_scatter = 0, enable_lro = 0}, txmode = {mq_mode = ETH_MQ_TX_NONE, pvid = 0,
      hw_vlan_reject_tagged = 0 '\000', hw_vlan_reject_untagged = 0 '\000', hw_vlan_insert_pvid = 0 '\000'},
    lpbk_mode = 0, rx_adv_conf = {rss_conf = {rss_key = 0x605e00 <lcore_power_info+35456> "",
        rss_key_len = 40 '(', rss_hf = 260}, vmdq_dcb_conf = {nb_queue_pools = (unknown: 0),
        enable_default_pool = 0 '\000', default_pool = 0 '\000', nb_pool_maps = 0 '\000', pool_map = {{
            vlan_id = 0, pools = 0} <repeats 64 times>}, dcb_tc = "\000\000\000\000\000\000\000"},
      dcb_rx_conf = {nb_tcs = (unknown: 0), dcb_tc = "\000\000\000\000\000\000\000"}, vmdq_rx_conf = {
        nb_queue_pools = (unknown: 0), enable_default_pool = 0 '\000', default_pool = 0 '\000',
        enable_loop_back = 0 '\000', nb_pool_maps = 0 '\000', rx_mode = 0, pool_map = {{vlan_id = 0,
            pools = 0} <repeats 64 times>}}}, tx_adv_conf = {vmdq_dcb_tx_conf = {
        nb_queue_pools = (unknown: 0), dcb_tc = "\000\000\000\000\000\000\000"}, dcb_tx_conf = {
        nb_tcs = (unknown: 0), dcb_tc = "\000\000\000\000\000\000\000"}, vmdq_tx_conf = {
        nb_queue_pools = (unknown: 0)}}, dcb_capability_en = 0, fdir_conf = {mode = RTE_FDIR_MODE_NONE,
      pballoc = RTE_FDIR_PBALLOC_64K, status = RTE_FDIR_NO_REPORT_STATUS, drop_queue = 0 '\000', mask = {
        vlan_tci_mask = 0, ipv4_mask = {src_ip = 0, dst_ip = 0, tos = 0 '\000', ttl = 0 '\000',
          proto = 0 '\000'}, ipv6_mask = {src_ip = {0, 0, 0, 0}, dst_ip = {0, 0, 0, 0}, tc = 0 '\000',
          proto = 0 '\000', hop_limits = 0 '\000'}, src_port_mask = 0, dst_port_mask = 0,
        mac_addr_byte_mask = 0 '\000', tunnel_id_mask = 0, tunnel_type_mask = 0 '\000'}, flex_conf = {
        nb_payloads = 0, nb_flexmasks = 0, flex_set = {{type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {
              0 <repeats 16 times>}}, {type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}},
          {type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}}, flex_mask = {{
            flow_type = 0, mask = '\000' <repeats 15 times>} <repeats 18 times>}}}, intr_conf = {lsc = 0,
      rxq = 0}}, mtu = 2030, min_rx_buf_size = 3968, rx_mbuf_alloc_failed = 0, mac_addrs = 0x513fe8b6c0,
  mac_pool_sel = {0 <repeats 128 times>}, hash_mac_addrs = 0x0, port_id = 11 '\v', promiscuous = 1 '\001',
  scattered_rx = 1 '\001', all_multicast = 0 '\000', dev_started = 0 '\000', lro = 0 '\000',
  rx_queue_state = '\000' <repeats 1023 times>, tx_queue_state = '\000' <repeats 1023 times>, dev_flags = 3,
  kdrv = RTE_KDRV_IGB_UIO, numa_node = -1, drv_name = 0x5d3888 ""}
(gdb)
```

对照口：

```gdb
(gdb) print *rte_eth_devices[12]->data
$6 = {name = "17:0.2", '\000' <repeats 25 times>, rx_queues = 0x513feaf500, tx_queues = 0x513feaf480,
  nb_rx_queues = 6, nb_tx_queues = 6, sriov = {active = 0 '\000', nb_q_per_pool = 0 '\000',
    def_vmdq_idx = 0, def_pool_q_idx = 0}, dev_private = 0x513fe1ae40, dev_link = {link_speed = 0,
    link_duplex = 0, link_autoneg = 1, link_status = 0}, dev_conf = {link_speeds = 0, rxmode = {
      mq_mode = ETH_MQ_RX_RSS, max_rx_pkt_len = 2048, split_hdr_size = 0, header_split = 0,
      hw_ip_checksum = 1, hw_vlan_filter = 0, hw_vlan_strip = 0, hw_vlan_extend = 0, jumbo_frame = 1,
      hw_strip_crc = 0, enable_scatter = 0, enable_lro = 0}, txmode = {mq_mode = ETH_MQ_TX_NONE, pvid = 0,
      hw_vlan_reject_tagged = 0 '\000', hw_vlan_reject_untagged = 0 '\000', hw_vlan_insert_pvid = 0 '\000'},
    lpbk_mode = 0, rx_adv_conf = {rss_conf = {rss_key = 0x605e00 <lcore_power_info+35456> "",
        rss_key_len = 40 '(', rss_hf = 260}, vmdq_dcb_conf = {nb_queue_pools = (unknown: 0),
        enable_default_pool = 0 '\000', default_pool = 0 '\000', nb_pool_maps = 0 '\000', pool_map = {{
            vlan_id = 0, pools = 0} <repeats 64 times>}, dcb_tc = "\000\000\000\000\000\000\000"},
      dcb_rx_conf = {nb_tcs = (unknown: 0), dcb_tc = "\000\000\000\000\000\000\000"}, vmdq_rx_conf = {
        nb_queue_pools = (unknown: 0), enable_default_pool = 0 '\000', default_pool = 0 '\000',
        enable_loop_back = 0 '\000', nb_pool_maps = 0 '\000', rx_mode = 0, pool_map = {{vlan_id = 0,
            pools = 0} <repeats 64 times>}}}, tx_adv_conf = {vmdq_dcb_tx_conf = {
        nb_queue_pools = (unknown: 0), dcb_tc = "\000\000\000\000\000\000\000"}, dcb_tx_conf = {
        nb_tcs = (unknown: 0), dcb_tc = "\000\000\000\000\000\000\000"}, vmdq_tx_conf = {
        nb_queue_pools = (unknown: 0)}}, dcb_capability_en = 0, fdir_conf = {mode = RTE_FDIR_MODE_NONE,
      pballoc = RTE_FDIR_PBALLOC_64K, status = RTE_FDIR_NO_REPORT_STATUS, drop_queue = 0 '\000', mask = {
        vlan_tci_mask = 0, ipv4_mask = {src_ip = 0, dst_ip = 0, tos = 0 '\000', ttl = 0 '\000',
          proto = 0 '\000'}, ipv6_mask = {src_ip = {0, 0, 0, 0}, dst_ip = {0, 0, 0, 0}, tc = 0 '\000',
          proto = 0 '\000', hop_limits = 0 '\000'}, src_port_mask = 0, dst_port_mask = 0,
        mac_addr_byte_mask = 0 '\000', tunnel_id_mask = 0, tunnel_type_mask = 0 '\000'}, flex_conf = {
        nb_payloads = 0, nb_flexmasks = 0, flex_set = {{type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {
              0 <repeats 16 times>}}, {type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}},
          {type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}, {
            type = RTE_ETH_PAYLOAD_UNKNOWN, src_offset = {0 <repeats 16 times>}}}, flex_mask = {{
            flow_type = 0, mask = '\000' <repeats 15 times>} <repeats 18 times>}}}, intr_conf = {lsc = 0,
      rxq = 0}}, mtu = 2030, min_rx_buf_size = 3968, rx_mbuf_alloc_failed = 0, mac_addrs = 0x513fe8d6c0,
  mac_pool_sel = {0 <repeats 128 times>}, hash_mac_addrs = 0x0, port_id = 12 '\f', promiscuous = 1 '\001',
  scattered_rx = 1 '\001', all_multicast = 0 '\000', dev_started = 1 '\001', lro = 0 '\000',
  rx_queue_state = '\000' <repeats 1023 times>, tx_queue_state = '\000' <repeats 1023 times>, dev_flags = 3,
  kdrv = RTE_KDRV_IGB_UIO, numa_node = -1, drv_name = 0x5d3888 ""}
```

nb_rx_queues 为 6 表明使用了 6 个收包队列，对比信息表明**异常接口**的 **dev_started** 字段为 0，这就存在问题。

dev_started 维护了 dpdk 内部对接口 down、up 的状态，在 rte_eth_dev_start 函数中有如下代码：

```c
        diag = (*dev->dev_ops->dev_start)(dev);
        if (diag == 0)
                dev->data->dev_started = 1;
        else
                return diag;
        rte_eth_dev_config_restore(port_id);

        if (dev->data->dev_conf.intr_conf.lsc == 0) {
                RTE_FUNC_PTR_OR_ERR_RET(*dev->dev_ops->link_update, -ENOTSUP);
                (*dev->dev_ops->link_update)(dev, 0);
        }
```

rte_eth_dev_stop 函数中有如下代码：
```c
        dev->data->dev_started = 0;
        (*dev->dev_ops->dev_stop)(dev);
```
dev_started 在接口 down 的时候被置为 0，在接口成功 up 的时候被设置为 1。再观察 **link_status** 字段的值，其值为 1 表明**接口物理状态 up**，同时参考寄存器的差异点，确定真正的问题是在调用 **rte_eth_dev_start** 的过程中失败了，这一失败导致 **rte_eth_dev_config_restore** 函数没有调用到，这个函数用来**重新配置接口的混淆模式**，没被调用则**混淆模式没有成功开启**。

**ethtool dump** 出的寄存器信息中 **RCTL** 寄存器的字段也能够反映**混淆模式的状态**，一起参照就能够**确认问题**。

#### 使用 dpdk_proc_info 修改网卡状态
上文的分析初步确定问题与当前网卡的状态有关系，网卡的混淆模式被关闭，为了确定这个问题，**修改 dpdk_proc_info 程序，开启网卡的混淆模式**，开启后重新查看网卡信息。

首先 dump 寄存器**确定设定生效**，然后**查看收包统计**，发现仍旧不能正常收包。继续调试，重新查看 **rte_eth_data** 信息，发现 **rx_mbuf_alloc_failed** 字段一直在增加，看来真正的问题是 mbuf 泄露了。

根据经验，问题多半是产品的代码引起的问题，交由产品排查，很快就找到了问题。

## rte_eth_dev_start 内部的一些原理
rte_eth_dev_start 函数中检查了调用每个 pmd 中 dev_start 函数的返回值，在 pmd 的 dev_start 函数中可能有多个【潜在的失败点】。

igb 网卡对应的 dev_start 函数为 eth_igb_start 函数，此函数可能在如下几个地方失败：

1. igb_hardware_init 异常
```c
        /* Initialize the hardware */
        if (igb_hardware_init(hw)) {
                PMD_INIT_LOG(ERR, "Unable to initialize the hardware");
                return -EIO;
        }
```
2. 申请 intr_vec 存储空间
```c
                intr_handle->intr_vec =
                        rte_zmalloc("intr_vec",
                                    dev->data->nb_rx_queues * sizeof(int), 0);
                if (intr_handle->intr_vec == NULL) {
                        PMD_INIT_LOG(ERR, "Failed to allocate %d rx_queues"
                                     " intr_vec\n", dev->data->nb_rx_queues);
                        return -ENOMEM;
                }
```

3. eth_igb_rx_init
```c
        /* This can fail when allocating mbufs for descriptor rings */
        ret = eth_igb_rx_init(dev);
        if (ret) {
                PMD_INIT_LOG(ERR, "Unable to initialize RX hardware");
                igb_dev_clear_queues(dev);
                return ret;
        }
```
4. 速率与双工配置
```c
                if (num_speeds == 0 || (!autoneg && (num_speeds > 1)))
                        goto error_invalid_config;
```

在上面四项中，**第三项经常遇到，其它几项很少遇到**。如果产品代码导致 mbuf 泄露，那可能会在为 rx ring 申请 mbuf 的时候失败。

需要注意的是当上面几项的异常出现时，dpdk 都会打印错误信息，如果 dpdk 的 stdout 与 stderr 被重定位到某个日志文件中，查看日志文件就能够发现问题。

## 总结
收包异常是 dpdk 程序经常会遇到的一大问题，一旦出现将会造成断网，是非常严重的问题。

收包异常对 dpdk 维护者也是一大挑战，根本原因在于【信息的欠缺】！常常只有一个不收包的结果，异常数据、日志等功能不完善，出现问题时经常需要临时修改代码添加调试信息，遇到【偶现】问题几乎完全无法解决。

针对这个欠缺项目，需要开发相应的功能来记录程序运行过程中的数据，这些数据将会【扩大】定位问题时的【输入信息】，当这些信息逐步完善时，问题就变得越来越简单了！



