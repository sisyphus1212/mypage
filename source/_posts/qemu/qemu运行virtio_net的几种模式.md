---
title: qemu运行virtio_net的几种模式
date: 2023-07-21 14:11:21
categories:
- [qemu,设备模拟]
tags:
- virtio-net
- tap
---

```sh
qemu-system-x86_64 -M q35,accel=kvm,kernel-irqchip=split \
    -smp cores=4 -m 4G -hda ./test.raw -device intel-iommu,intremap=on \
    -device pxb-pcie,id=pcie.1,bus_nr=8,bus=pcie.0    \
    -device ioh3420,id=pcie_port1,bus=pcie.1,chassis=1 \
    -device pcie-root-port,bus=pcie.0,id=rp1,slot=1 \
    -device pcie-root-port,bus=pcie.0,id=rp2,slot=2 \
    -device pcie-root-port,bus=pcie.0,id=rp3,slot=3,bus-reserve=3 \
    -netdev tap,id=tap_dev0,ifname=tap_dev0,vhost=off,script=/etc/qemu-ifup,downscript=no,queues=6,br=docker0 \
    -device virtio-net-pci,netdev=tap_dev0,bus=rp2,multifunction=on \
    -device e1000e,netdev=tap_dev1,bus=pcie.0 \
    -netdev tap,ifname=tap_dev1,id=tap_dev1,vhost=off,script=/etc/qemu-ifup,downscript=no,queues=6,br=docker0 \
    -monitor telnet:127.0.0.1:6666,server,nowait \
    -qmp unix:/tmp/qmp-sock,server,nowait \
    -serial mon:stdio -nographic
```