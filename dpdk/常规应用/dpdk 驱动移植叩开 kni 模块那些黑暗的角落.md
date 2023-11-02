# dpdk 驱动移植叩开 kni 模块那些黑暗的角落
## 前言
kni 模块是早期 dpdk 版本中一个非常重要的功能，它充当了用户态驱动与内核协议栈之间的桥梁，让 dpdk 程序能够上送流量到内核协议栈，同时也支持使用ethtool、ifconfig 等重要的网络管理命令。

## kni 支持 ethtool 带来的问题
kni 为了实现 ethtool 获取网卡信息的功能，对 igb、ixgbe 等系列网卡的官方驱动进行修改，意味着 dpdk 内部维护着**两套驱动代码**，一套是**用户态驱动代码**，另一套是 kni 模块中的**内核驱动代码**。这样的情况提高了维护的成本，同时也更容易带来问题。

高版本 dpdk 中 kni 模块已经**移除了内核驱动的代码**，不再支持 ethtool 获取诸多网卡信息，可是也没有其它替代 ethtool 的工具提供，不由地让人感慨套路之深！

## 为什么要修改 kni?
既然高版本已经干掉了 kni 的大部分功能，那我们应该追随高版本的发展方向。奈何公司内部使用的 dpdk 版本为 16.04，许多产品仍旧使用 kni 模块来通过ethtool 获取信息，最近遇到了需要适配 x553 新网卡的问题，为了**避免产品代码改动**，需要适配 kni，只能与 kni 短兵相接了！

## 新网卡的型号
新网卡为 x553 网卡，属于 ixgbe 网卡系列，dpdk 16.04 并不支持此款网卡。**pmd 驱动代码从高版本合入，kni 中的代码从 ixgbe-5.8.1 内核驱动合入**。

下文对适配过程中遇到的一些具体的问题进行记录
### 1. 添加新的 device id 

dpdk-16.04 支持的网卡型号在 **rte_pci_dev_ids.h** 头文件中被定义，适配新网卡需要**在 rte_pci_dev_ids.h 中添加相应的项目**。

kni 中使用官方驱动适配，正常方式应该是使用 **pci_device_table** 来定义支持的网卡型号，可是这个 pci_device_table 并没有被使用。

**kni_ioctl_create** 函数中**也通过包含 rte_pci_dev_ids.h 来匹配网卡**，这与pmd 保持一致。

x553 属于 ixgbe 网卡，**dpdk-16.04 kni** 驱动中在 **ixgbe_pci_tbl** 中定义支持的网卡型号，这里的定义表明**适配的 ixgbe 驱动支持的网卡型号**，阅读代码发现 **ixgbe_pci_tbl** 表中支持的网卡型号与 **rte_pci_dev_ids.h** 中定义的 ixgbe 网卡型号并**不一致**，是其中的一个**子集**。

当 **rte_pci_dev_ids.h** 中添加了新的 **ixgbe** 网卡，却没有适配 kni 时，在 dpdk 程序初始化的时候仍旧会执行 ixgbe 驱动的 probe 函数，就可能造成问题，

为此首先在 **ixgbe_pci_tbl 中添加新网卡项**目，然后在 **probe 函数中也使用当前设备的 vendor id 与 device id 在 ixgbe_pci_tbl 中匹配**，匹配成功则执行后续流程，失败则直接返回。

### ixgbe_init_shared_code 函数

kni 适配中重点修改 **ixgbe_init_shared_code** 函数，此函数中关键过程如下：

1. 根据 vendor id 与 device id 设置 mac_type
2. 根据 mac_type 调用不同的初始化函数

针对 x553 网卡，初始化过程如下：

1. ixgbe_set_mac_type 中设定 mac_type 为 ixgbe_mac_X550EM_a
2. 调用 ixgbe_init_ops_X550EM_a 函数完成初始化过程

ixgbe_init_ops_X550EM_a 函数调用层次如下：

```
ixgbe_init_ops_X550EM_a
    ixgbe_init_ops_X550EM
        ixgbe_init_ops_X550
            ixgbe_init_ops_X540
                ixgbe_init_phy_ops_generic
                ixgbe_init_ops_generic
```

在初始化过程中完成对 **phy、mac、eeprom** 等结构虚函数表的赋值，一些函数的**赋值过程可能有多次**！

完成其它函数的适配后，使用 kni 程序进行测试，结果发现系统崩溃了，一通分析发现问题与网卡的 **reset** 函数有关。

### ixgbe_reset_hw_82599 函数中的注释
首先找到一个**正常的版本**进行**对比**，82599 测试过能够正常工作，于是阅读 **ixgbe_reset_hw_82599** 函数，发现它的大部分内容都被注释掉了，注释的截止位置如下：

```c
     /* Store the permanent mac address */
     hw->mac.ops.get_mac_addr(hw, hw->mac.perm_addr);
```

直接完全注释 **ixgbe_reset_hw_X550em** 后测试发现，ifconfig 看到的接口信息中 **mac** 地址不正常，于是参照 **ixgbe_reset_hw_82599** 的代码进行修改，注释掉 **get_mac_addr** 之前的代码，测试正常。

问题在于网卡在 dpdk 程序调用 **rte_eal_init** 的时候**已经被初始化**了，并且已经被用户态程序使用，kni 中**重新初始化正在被使用的网卡**就会导致异常。

阅读其它代码，也能够看到注释的项目，大部分内容都跟硬件操作有关，且注释格式凌乱，像某种非法地带～

### ixgbe_get_settings 函数的修改

初始化过程搞定后，运行 kni 程序，然后执行 ethtool 进行测试，发现输出的链路模式不正确，想到应该要适配 **ixgbe_get_settings** 函数。

**ixgbe_get_settings** 中的细节非常多，为了避免造成问题，对 x553 型号的网
卡单独判断，使用新的 **ixgbe_get_settings** 函数。

执行 ethtool 的测试结果如下：

```bash
Settings for vEth0_0:
        Supported ports: [ TP ]
        Supported link modes:   10baseT/Full
                                100baseT/Full
                                1000baseT/Full
        Supported pause frame use: Symmetric
        Supports auto-negotiation: Yes
        Advertised link modes:  10baseT/Full
                                100baseT/Full
                                1000baseT/Full
        Advertised pause frame use: Symmetric
        Advertised auto-negotiation: Yes
        Speed: Unknown!
        Duplex: Full
        Port: Twisted Pair
        PHYAD: 0
        Transceiver: external
        Auto-negotiation: on
        MDI-X: Unknown
        Supports Wake-on: d
        Wake-on: d
        Current message level: 0x00000007 (7)
                               drv probe link
        Link detected: yes
```

Link detected 的输出结果为 yes，而 Speed 的值却为 Unknown，这看上去就不太对，不过支持的链路模式与接口类型都正确了。

阅读 ixgbe_get_settings 函数代码，发现了如下语句：

```c
 332     if (!in_interrupt()) {
 333         hw->mac.ops.check_link(hw, &link_speed, &link_up, false);
 334     } else { 
 335         /*
 336          * this case is a special workaround for RHEL5 bonding
 337          * that calls this routine from interrupt context
 338          */
 339         link_speed = adapter->link_speed;
 340         link_up = adapter->link_up;
 341     }
```

大多数情况下都会走到 if 判断中，调用 **check_link** 来获取当前网卡的状态，
基于这个点进行修改，能够获取到速率了！

### check_link 同时调用的问题？
在解决上述问题的过程中，我想到了一个问题:当关闭网卡 lsc 中断时，dpdk 程序中调用 **rte_eth_link_get_nowait** 获取状态也会调用到 ixgbe 的 check_link 函数，同时业务脚本中调用 **ethtool** 获取网卡状态也会调用 **check_link** 函数，可能存在同时调用的问题。

阅读代码确认，ixgbe 驱动的 **check_link** 函数实质上是通过获取 **IXGBE_LINKS** 寄存器来确定接口状态的，这个寄存器手册中没有说明不能同时读取，理论上没有太大问题！

## 总结
新网卡的适配带来了 dpdk 升级的问题，这是产品的痛点。为了解决这个痛点常常要做一些移植工作，这些移植工作总结起来有如下几个类别：

1. dpdk 高版本驱动、功能移植到低版本
2. 内核驱动移植到 kni
3. 内核驱动移植到 pmd 中

这些工作是一个深入研究 dpdk 的机会，其难点在于理清楚某功能、网卡从初始化到被使用的全过程，对这些过程越了解，做起这些工作来越有底气！