---
title: qemu运行virtio_net的几种模式
date: 2023-07-21 14:11:21
categories:
- [qemu,设备模拟]
tags:
- virtio-net
- tap
- 网络设备
- dpdk
- vhost-user
---

# tap 模式
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

# vhost-user 模式
```sh
#dpdk vhost-user:

#vm:
qemu-system-x86_64 -machine q35,accel=kvm,usb=off,vmport=off,dump-guest-core=off,kernel_irqchip=split -cpu host -m 1G \
                                        -object memory-backend-file,id=ram-node0,prealloc=yes,mem-path=/dev/hugepages/dpdk-vdpa,share=yes,size=1G \
                                        -numa node,nodeid=0,memdev=ram-node0 \
                                        -smp 2 ./test.raw \
                                        -enable-kvm \
                                        -netdev vhost-user,chardev=charnet0,id=hostnet0,queues=6 \
                                        -chardev socket,id=charnet0,path=/tmp/vdpa-socket0,server=on \
                                        -device pcie-root-port,port=0x10,chassis=1,id=pci.4,bus=pcie.0,multifunction=on,addr=0x2 \
                                        -device virtio-net-pci,netdev=hostnet0,id=net0,mac=52:54:00:00:34:56,bus=pci.4,mq=on,host_mtu=3500 \
                                        -nographic -serial mon:stdio -monitor tcp:127.0.0.1:3333,server,nowait
```
