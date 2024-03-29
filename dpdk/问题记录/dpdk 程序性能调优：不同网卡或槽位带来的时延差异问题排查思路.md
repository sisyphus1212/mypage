---
title: dpdk 程序性能调优：不同网卡或槽位带来的时延差异问题排查思路
date: 2022-09-20 16:04:02
index_img: https://www.dpdk.org/wp-content/uploads/sites/35/2021/03/DPDK_logo-01-1.svg
categories:
- [dpdk,网络开发,数据包处理]
tags:
 - dpdk
 - 多核,亲核性
---

## 问题描述
某千兆电口网卡性能测试时发现**不同网卡测试出来的时延差异较大**！

## 排查方法

### 1. 确定网卡所在的 PCIE 槽位差异的影响

排查方法：**将网卡更换到不同的槽位进行测试！**

### 2. 确定 PCIE link 状态的影响

排查方法：**执行 lspci -s 【设备bus ID】 -vvv 查看输出信息**。

关键信息：

1. Physical Slot: 5-2
2. LnkSta: Speed 5GT/s (ok), Width x4 (ok)

### 3. 排查 PCIE 硬件连接方式影响

排查方法：**执行 lspci -tv 命令观察 pci 网卡的连接关系。** 对于那些连接到一个内部 swtich 的槽位，时延会偏高。

### 3. 不同设备是否存在跨 numa 的问题
查看 **/sys/bus/pci/devices/*/numa_node** 获取 pci 网卡所在的 numa 节点。

网卡所在的 **numa** 节点需要与 **dpdk** 收发包使用的 **numa** 节点及 **dpdk** 初始化网卡接口配置的 **mempool、rx ring、tx ring** 等数据结构所在的 numa 保持一致， 当不一致时就会存在跨 numa 的情况。

### 4. 更换网卡
在这个问题里，一张网卡可以，一张网卡不可以，差异点集中在硬件上，可以更换相同型号的其它网卡进行测试，排除硬件问题。
## 软件优化方法
1. 通过 cpu 隔离减少 dpdk 收发线程所在核被其它事务打断的情况
2. 减少每次的 burst size 来降低时延
