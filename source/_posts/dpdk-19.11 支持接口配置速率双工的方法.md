# dpdk-19.11 支持接口配置速率双工的方法
# 前言
常见的 igb 电口网卡有支持速率双工配置的需求，在 dpdk-19.11 中却没有配置网卡速率双工的接口，为此需要进行开发，实现方法需要通过研究不同网卡的驱动代码来确定。

本文中以 igb 网卡驱动为例进行描述。

# 研究 igb 网卡驱动
dpdk-19.11 中的 igb 网卡驱动在执行 eth_igb_start up 接口的时候会配置速率双工。

相关的代码如下：

```c
1349     /* Setup link speed and duplex */
1350     speeds = &dev->data->dev_conf.link_speeds;
1351     if (*speeds == ETH_LINK_SPEED_AUTONEG) {
1352         hw->phy.autoneg_advertised = E1000_ALL_SPEED_DUPLEX;
1353         hw->mac.autoneg = 1;
1354     } else {
1355         num_speeds = 0;
1356         autoneg = (*speeds & ETH_LINK_SPEED_FIXED) == 0;
1357     
1358         /* Reset */
1359         hw->phy.autoneg_advertised = 0;
1360         
1361         if (*speeds & ~(ETH_LINK_SPEED_10M_HD | ETH_LINK_SPEED_10M |
1362                 ETH_LINK_SPEED_100M_HD | ETH_LINK_SPEED_100M |
1363                 ETH_LINK_SPEED_1G | ETH_LINK_SPEED_FIXED)) {
1364             num_speeds = -1;
1365             goto error_invalid_config;
1366         }
1367         if (*speeds & ETH_LINK_SPEED_10M_HD) {
1368             hw->phy.autoneg_advertised |= ADVERTISE_10_HALF;
1369             num_speeds++;
1370         }   
...............
1387         if (num_speeds == 0 || (!autoneg && (num_speeds > 1)))
1388             goto error_invalid_config;
1389 
1390         /* Set/reset the mac.autoneg based on the link speed,
1391          * fixed or not
1392          */
1393         if (!autoneg) {
1394             hw->mac.autoneg = 0;
1395             hw->mac.forced_speed_duplex =
1396                     hw->phy.autoneg_advertised;
1397         } else {
1398             hw->mac.autoneg = 1;
1399         }

1402     e1000_setup_link(hw);
```
上述代码的主要逻辑如下：

1. 获取 dev->data->dev_conf.link_speeds 变量中设置的 link_speeds，获取速率双工配置状态
2. 根据 link_speeds 变量的值设置驱动内部变量如 hw->phy.autoneg_advertised、hw->mac.autoneg、hw->mac.forced_speed_duplex 的值
3. 调用 e1000_setup_link 配置设置的速率双工

按照上面的流程，我们只需要设置 dev->data->dev_conf.link_speeds 的值，然后重新将接口 up 起来就能够实现速率双工配置了。

# 测试验证过程
经过上文的分析，已经确定了 igb 网卡速率双工配置的方法，需要验证可行性。
可以在 e1000_setup_link 函数调用前执行如下代码：

```c
 hw->mac.autoneg = 0;
 hw->mac.forced_speed_duplex = ADVERTISE_100_FULL;
```
这两行代码配置接口速率双工为强制 100M 全双工，修改代码后使用 kni 程序测试，对端接口绑定到内核驱动上，测试有效！

# igb 网卡默认的速率双工配置
设置方案确定后，不能忘了 igb 网卡默认的速率双工配置项目。一般来说，在 rte_eth_dev_configure 未通过 dev_conf 设定 link_speeds 的值则默认为 0。

eth_igb_dev_init 函数中的如下代码配置接口使用自协商模式，并指定协商速率为所有支持的速率与双工模式。

```c
 793     hw->mac.autoneg = 1;
 794     hw->phy.autoneg_wait_to_complete = 0;
 795     hw->phy.autoneg_advertised = E1000_ALL_SPEED_DUPLEX;
```
# dpdk-19.11 获取接口支持的速率双工配置
在设置速率双工前，可以添加一些检查，检查待设置的模式当前网卡是否支持。可以通过调用 rte_eth_dev_info_get 函数来获取 dev_info 结构来实现，dev_info 结构中的 speed_capa 字段代表了当前网卡支持的速率双工配置。

对 igb 网卡来说，speed_capa 字段通过 eth_igb_infos_get 函数的如下代码来填充：

```c
2286     dev_info->speed_capa = ETH_LINK_SPEED_10M_HD | ETH_LINK_SPEED_10M |
2287             ETH_LINK_SPEED_100M_HD | ETH_LINK_SPEED_100M |
2288             ETH_LINK_SPEED_1G;
```
获取到了之后就可以进行检查！

# 总结
本文以 igb 驱动为例描述了 dpdk-19.11 支持接口配置速率双工的方法，这一方法适用于多个驱动，是一个相对通用的方法。速率双工配置也是网卡驱动应当对外提供的常见功能，不过这里 dpdk 的处理过程有些特别，它将配置集中到对 dev->data->dev_conf.link_speeds 变量的设定上了！