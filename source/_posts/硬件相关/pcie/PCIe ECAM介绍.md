---
title: PCIe ECAM介绍
date: 2024-03-23 16:05:52
categories:
  - [接口协议]
tags:
- pcie
- mmio
---

ECAM 全称：PCI Express Enhanced Configuration Access Mechanism
ECAM是访问PCIe配置空间一种机制，PCIe配置空间大小是4k

4kbyte寄存器地址空间，需要12bit bit 0~bit11

Function Number bit 12~bit 14

Device Number bit 15~bit 19

Bus Number bit 20～bit 27

如何访问一个PCIe设备的配置空间呢

比如ECAM 基地址是0xd0000000

devmem 0xd0000000就是访问00:00.0 设备偏移0寄存器,就是Device ID和Vendor ID

devmem 0xd0100000就是访问01:00.0 设备偏移0寄存器

drivers/pci/ecam.c实现ECAM配置访问

# qemu 软件仿真shixian
```c

```