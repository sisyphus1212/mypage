# dpdk 中 rte_eth_link_get_wait、nowait 函数研究
## 对 rte_eth_link_get_wait\nowait 函数的研究

与 rte_eth_link_get_nowait 函数功能类似的函数是 rte_eth_link_get 函数。 这两个函数的主要逻辑如下：

```c
{
        struct rte_eth_dev *dev;

        RTE_ETH_VALID_PORTID_OR_RET(port_id);
        dev = &rte_eth_devices[port_id];

        if (dev->data->dev_conf.intr_conf.lsc != 0)
                rte_eth_dev_atomic_read_link_status(dev, eth_link);
        else {
                RTE_FUNC_PTR_OR_RET(*dev->dev_ops->link_update);
                (*dev->dev_ops->link_update)(dev, 1); /* 1 => wait，0 => no wait */
                *eth_link = dev->data->dev_link;
        }
}
```

## 使能 lsc 中断的情况 
如果使能了 lsc——link status change 中断，则直接原子读取 dev 中的 data->dev_link 成员，根据读取到的结果来判断链接状态是否改变。使用这种方式的应用程序需要注册一个 lsc 中断的回调函数，可以参考 examples/link_status_interrupt。

在 link_status_interrupt 的 demo 中，注册 lsc 中断回调函数的语句如下：

```c
rte_eth_dev_callback_register(portid,
                        RTE_ETH_EVENT_INTR_LSC, lsi_event_callback, NULL);
```
在 lsi_event_callback 函数的核心是调用 rte_eth_link_get_nowait 来获取链路 状态。

## 未使能 lsc 中断的情况
如果没有使用 lsc 中断，则调用 pmd 驱动中实现的 dev_ops->link_update 函数来完成。 wait 与 nowait 的区别就是在 link_update 函数中体现的。

**一般来说 wait 方式倾向于检测到接口 up 状态**，在设定的时间内（9s) 内不断的轮询接口状态，当**获取到一次 up 就立刻返回**，或者**当时间耗尽时仍旧为 down 则返回 down 的状态**。

nowait 方式则不存在这种倾向，它直接读取接口的当前状态返回。

这里 link_update 的返回值表示**链路状态与上一次的状态相比是否有变化**，有变化则返回 0，无变化则返回 -1。

## ixgbe 驱动中 link_update 函数的实现
ixgbe pmd 驱动中 link_update 函数的源码在 ixgbe_ethdev.c 文件中实现，摘录如下：


```c
static int
ixgbe_dev_link_update(struct rte_eth_dev *dev, int wait_to_complete)
{
        struct ixgbe_hw *hw = IXGBE_DEV_PRIVATE_TO_HW(dev->data->dev_private);
        struct rte_eth_link link, old;
        ixgbe_link_speed link_speed = IXGBE_LINK_SPEED_UNKNOWN;
        int link_up;
        int diag;

        link.link_status = ETH_LINK_DOWN;
        link.link_speed = 0;
        link.link_duplex = ETH_LINK_HALF_DUPLEX;
        memset(&old, 0, sizeof(old));
        rte_ixgbe_dev_atomic_read_link_status(dev, &old);

        hw->mac.get_link_status = true;

        /* check if it needs to wait to complete, if lsc interrupt is enabled */
        if (wait_to_complete == 0 || dev->data->dev_conf.intr_conf.lsc != 0)
                diag = ixgbe_check_link(hw, &link_speed, &link_up, 0);
        else
                diag = ixgbe_check_link(hw, &link_speed, &link_up, 1);

        if (diag != 0) {
                link.link_speed = ETH_SPEED_NUM_100M;
                link.link_duplex = ETH_LINK_FULL_DUPLEX;
                rte_ixgbe_dev_atomic_write_link_status(dev, &link);
                if (link.link_status == old.link_status)
                        return -1;
                return 0;
        }

        if (link_up == 0) {
                rte_ixgbe_dev_atomic_write_link_status(dev, &link);
                if (link.link_status == old.link_status)
                        return -1;
                return 0;
        }
        link.link_status = ETH_LINK_UP;
        link.link_duplex = ETH_LINK_FULL_DUPLEX;

        switch (link_speed) {
        default:
        case IXGBE_LINK_SPEED_UNKNOWN:
                link.link_duplex = ETH_LINK_FULL_DUPLEX;
                link.link_speed = ETH_SPEED_NUM_100M;
                break;

        case IXGBE_LINK_SPEED_100_FULL:
                link.link_speed = ETH_SPEED_NUM_100M;
                break;

        case IXGBE_LINK_SPEED_1GB_FULL:
                link.link_speed = ETH_SPEED_NUM_1G;
                break;

        case IXGBE_LINK_SPEED_10GB_FULL:
                link.link_speed = ETH_SPEED_NUM_10G;
                break;
        }
        rte_ixgbe_dev_atomic_write_link_status(dev, &link);

        if (link.link_status == old.link_status)
                return -1;

        return 0;
}
```
ixgbe_check_link 函数中会读取硬件寄存器来获取链路状态内容。这之后链路的当前状态会被更新到 dev 中的 data->dev_link 成员中，update_link 函数执行完成后，rte_eth_link_get_nowait、rte_eth_link_get 函数会将 **dev 中更新后 的 data->dev_link 成员的值写入到传入的 eth_link 参数中**，上层通过该参数就能获取到当前的链路状态。

## dpdk 获取到的链路状态到底是什么组件的状态？
dpdk 中获取到的链路状态实际上是 phy 的状态，在实际应用中这个状态会产生的震荡现象，这其实也是 phy 状态的抖动造成的结果，阅读网卡手册能够找到 MAC 寄存器中也存在 LINK status 寄存器，是否可以考虑获取 MAC 中与链路状态相关的寄存器来作为网卡链路状态呢？这种方式是否能够行得通呢？这需要进一步的思考与尝试了！


