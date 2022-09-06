# dpdk-16.04 igb crc length 统计问题
## 问题描述

i350 igb 电口，调用 dpdk rte_eth_stats_get 获取到的接口发包字节统计，每个包少了 crc len 长度，导致根据此统计计算的 bps 不准确。

## 问题分析

### 底层驱动获取网卡收发包字节统计数据

igb 驱动底层统计函数为 eth_igb_stats_get 函数，此函数通过读取网卡统计相关寄存器实现功能。向上层返回的收发包字节统计代码如下：

```c
	rte_stats->ibytes   = stats->gorc;
	rte_stats->obytes   = stats->gotc;
```

底层读寄存器处的代码逻辑如下：

```c
/* Workaround CRC bytes included in size, take away 4 bytes/packet */
	stats->gorc += E1000_READ_REG(hw, E1000_GORCL);
	stats->gorc += ((uint64_t)E1000_READ_REG(hw, E1000_GORCH) << 32);
	stats->gorc -= (stats->gprc - old_gprc) * ETHER_CRC_LEN;
	stats->gotc += E1000_READ_REG(hw, E1000_GOTCL);
	stats->gotc += ((uint64_t)E1000_READ_REG(hw, E1000_GOTCH) << 32);
	stats->gotc -= (stats->gptc - old_gptc) * ETHER_CRC_LEN;
```

在上述逻辑中，每个收发的报文都【减掉 crc len 长度】字节，代码的注释表明这部分逻辑正是为了规避 CRC 字节被计算到每个报文长度中的问题。

dpdk 内部有一个针对网卡是否 strip crc 的配置功能——**hw_strip_crc**，默认为 0，表明网卡不 strip crc，设置为 1 表明网卡使能 strip crc 功能。

### hw_strip_crc 在 igb 驱动中的影响
**1. 对硬件的影响**
    
   在 up 接口的时候，使用 igb 网卡时，dpdk 会调用 **eth_igb_rx_init** 函数，在这个函数中有对 **hw_strip_crc** 进行判断，根据判断的结果设定硬件状态。
    
   相关代码如下：

```c
    /* Setup the Receive Control Register. */
            if (dev->data->dev_conf.rxmode.hw_strip_crc) {
                    rctl |= E1000_RCTL_SECRC; /* Strip Ethernet CRC. */
    
                    /* set STRCRC bit in all queues */
                    if (hw->mac.type == e1000_i350 ||
                        hw->mac.type == e1000_i210 ||
                        hw->mac.type == e1000_i211 ||
                        hw->mac.type == e1000_i354) {
                            for (i = 0; i < dev->data->nb_rx_queues; i++) {
                                    rxq = dev->data->rx_queues[i];
                                    uint32_t dvmolr = E1000_READ_REG(hw,
                                            E1000_DVMOLR(rxq->reg_idx));
                                    dvmolr |= E1000_DVMOLR_STRCRC;
                                    E1000_WRITE_REG(hw, E1000_DVMOLR(rxq->reg_idx), dvmolr);
                            }
                    }
            } else {
                    rctl &= ~E1000_RCTL_SECRC; /* Do not Strip Ethernet CRC. */
    
                    /* clear STRCRC bit in all queues */
                    if (hw->mac.type == e1000_i350 ||
                        hw->mac.type == e1000_i210 ||
                        hw->mac.type == e1000_i211 ||
                        hw->mac.type == e1000_i354) {
                            for (i = 0; i < dev->data->nb_rx_queues; i++) {
                                    rxq = dev->data->rx_queues[i];
                                    uint32_t dvmolr = E1000_READ_REG(hw,
                                            E1000_DVMOLR(rxq->reg_idx));
                                    dvmolr &= ~E1000_DVMOLR_STRCRC;
                                    E1000_WRITE_REG(hw, E1000_DVMOLR(rxq->reg_idx), dvmolr);
                            }
                    }
            }
```

上述逻辑表明，igb 网卡 dpdk pmd 驱动中，hw_strip_crc 的配置将会被用于设定网卡【接收控制寄存器】与每个【收包队列的配置寄存器】。
    
我们的程序默认是关闭 **hw_strip_crc** 的，在这种情况下网卡不 strip crc，同时获取收包字节统计的时候为每个收到的包减掉 crc 长度，这个行为与注释内容一致。但是当 hw_strip_crc 使能后，收包字节统计中仍旧为每个包减掉 crc 长度，这里存在问题。
    
   **初步的解释是网卡 strip crc 并不会在硬件侧减掉每个包的 crc 长度，包的字节统计与 hw_strip_crc 功能是否使能并无关系。**
    
   使用 testpmd 测试：
    
   1. 关闭 crc strip

 ```c
    testpmd> start
      io packet forwarding - CRC stripping disabled - packets/burst=32
      nb forwarding cores=1 - nb forwarding ports=1
      RX queues=1 - RX desc=128 - RX free threshold=32
      RX threshold registers: pthresh=8 hthresh=8 wthresh=4
      TX queues=1 - TX desc=512 - TX free threshold=0
      TX threshold registers: pthresh=8 hthresh=1 wthresh=16
      TX RS bit threshold=0 - TXQ flags=0x0
    testpmd> show port stats all
    
      ######################## NIC statistics for port 0  ########################
      RX-packets: 0          RX-missed: 0          RX-bytes:  0
      RX-errors: 0
      RX-nombuf:  0
      TX-packets: 0          TX-errors: 0          TX-bytes:  0
      ############################################################################
    testpmd> show port stats all
    
      ######################## NIC statistics for port 0  ########################
      RX-packets: 3          RX-missed: 0          RX-bytes:  180
      RX-errors: 0
      RX-nombuf:  0
      TX-packets: 3          TX-errors: 0          TX-bytes:  180
      ############################################################################
 ```

   对端发出 3 个 64-byte 的包，crc_len 长度被减掉。
    
   2. 开启 crc strip

   ```c
    testpmd> start
      io packet forwarding - CRC stripping enabled - packets/burst=32
      nb forwarding cores=1 - nb forwarding ports=1
      RX queues=1 - RX desc=128 - RX free threshold=32
      RX threshold registers: pthresh=8 hthresh=8 wthresh=4
      TX queues=1 - TX desc=512 - TX free threshold=0
      TX threshold registers: pthresh=8 hthresh=1 wthresh=16
      TX RS bit threshold=0 - TXQ flags=0x0
    
    testpmd> show port stats 0
    
      ######################## NIC statistics for port 0  ########################
      RX-packets: 6          RX-missed: 0          RX-bytes:  360
      RX-errors: 0
      RX-nombuf:  0
      TX-packets: 6          TX-errors: 0          TX-bytes:  360
      ############################################################################
    testpmd> show port stats 0
    
      ######################## NIC statistics for port 0  ########################
      RX-packets: 9          RX-missed: 0          RX-bytes:  540
      RX-errors: 0
      RX-nombuf:  0
      TX-packets: 9          TX-errors: 0          TX-bytes:  540
      ############################################################################
   ```

   对端发出 3 个 64-byte 的包，crc_len 长度被减掉，与关闭 crc strip 的效果一致表明猜测合理。
    
**2. 对软件的影响**
    
   在 eth_igb_rx_init  函数中有如下代码：
    
   ```c
    rxq->crc_len = (uint8_t)(dev->data->dev_conf.rxmode.hw_strip_crc ?
                                                            0 : ETHER_CRC_LEN);
   ```

   此代码使用 hw_strip_crc 配置判断，收包队列中是否减掉 crc_len。
   hw_strip_crc 开启时，rxq->crc_len 长度赋值为 0 表明不需要减掉此部分长度，此部分工作由网卡完成。
   hw_strip_crc 关闭时，rxq->crc_len 赋值为 ETHER_CRC_LEN 来在收包逻辑中减掉 crc_len 长度，这里最终计算得出的报文长度会填充到报文所在 mbuf 的 pkt_len 字段中。
    

### 发包时 crc len 的处理

发包的时候需要填充报文的 CRC，没有特别的处理。igb dpdk pmd 驱动中在发包字节统计中减掉每个发出包的 CRC 长度。

## 解决方案

修改 igb 网卡获取网卡统计代码，取消减掉每个发出包的 crc len 的逻辑。修改 patch 如下：

```c
ndex: drivers/net/e1000/igb_ethdev.c
===================================================================
--- drivers/net/e1000/igb_ethdev.c     
+++ drivers/net/e1000/igb_ethdev.c
@@ -1729,12 +1729,13 @@
        /* Both registers clear on the read of the high dword */

        /* Workaround CRC bytes included in size, take away 4 bytes/packet */
+       /* included CRC length to fix igb netcard bps leak */
        stats->gorc += E1000_READ_REG(hw, E1000_GORCL);
        stats->gorc += ((uint64_t)E1000_READ_REG(hw, E1000_GORCH) << 32);
-        stats->gorc -= (stats->gprc - old_gprc) * ETHER_CRC_LEN;
+       /* stats->gorc -= (stats->gprc - old_gprc) * ETHER_CRC_LEN; */
        stats->gotc += E1000_READ_REG(hw, E1000_GOTCL);
        stats->gotc += ((uint64_t)E1000_READ_REG(hw, E1000_GOTCH) << 32);
-       stats->gotc -= (stats->gptc - old_gptc) * ETHER_CRC_LEN;
+       /* stats->gotc -= (stats->gptc - old_gptc) * ETHER_CRC_LEN; */

        stats->rnbc += E1000_READ_REG(hw, E1000_RNBC);
        stats->ruc += E1000_READ_REG(hw, E1000_RUC);
```

## 其它网卡如何处理 hw_strip_crc 配置的？

ixgbe: 与 Igb 处理过程一致，硬件 + 软件

i40e: 只用来设置 rxq->crc_len，没有硬件相关配置

ice: 同 i40e