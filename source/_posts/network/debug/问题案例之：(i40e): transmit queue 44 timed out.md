# 问题案例之：(i40e): transmit queue 44 timed out
## 问题描述

今天接到一个反馈，问题是虚拟机网络出现异常，现象是无法通过 web 访问虚拟机中的业务。

虚拟机有两台，两台都无法通过 web 访问，从另外一台宿主机 ping 虚拟机的 ip 也 ping 不通。

进一步确认发现，并不是一开始就不通，而是**运行了很长时间后突然出现不通。**

## 问题的排查过程

根据问题的描述，首先重点排查虚拟机，有如下过程：

1. 从宿主机串口接入到虚拟机中
2. 查看虚拟机中的业务是否正常运行，如 apache 等，确认业务程序正常运行
3. 查看虚拟机的 dmesg 信息，查看是否有异常堆栈，确认没有异常堆栈
3. 查看虚拟机的网络接口，确定接口正常 up
4. ethtool -S 查看网络接口统计信息，确认没有异常统计数据
4. 虚拟机中 ping 另外一台宿主机的 ip，两台虚拟机都 ping 不通
5. 虚拟机中互 ping 能够 ping 通，虚拟机中使用 wget 模拟访问 web，连接正常建立
6. 虚拟机与宿主机之间能够 ping 通

经过上面的排查，确定虚拟机应该是正常的，这样看**问题大概率应该出在宿主机上**。

查看网络拓扑，确定虚拟机会通过宿主机的 eno3 接口收发包，继续从虚拟机中 ping 另外一台物理机的 ip，同时使用 tcpdump 在宿主机上抓包，发现一直在发 arp，但是没有人响应。

继续排查宿主机，发现内核有一个异常堆栈，信息如下：


```
[Thu Nov  5 16:44:42 2020] WARNING: CPU: 45 PID: 0 at net/sched/sch_generic.c:300 dev_watchdog+0x242/0x250
[Thu Nov  5 16:44:42 2020] NETDEV WATCHDOG: eno3 (i40e): transmit queue 44 timed out
[Thu Nov  5 16:44:42 2020] Modules linked in: tcp_lp fuse vhost_net vhost macvtap macvlan xt_CHECKSUM iptable_mangle ipt_MASQUERADE nf_nat_masquerade_ipv4 iptable_nat nf_nat_ipv4 nf_nat nf_conntrack_ipv4 nf_defrag_ipv4 xt_conntrack nf_conntrack libcrc32c ipt_REJECT nf_reject_ipv4 tun ebtable_filter ebtables ip6table_filter ip6_tables iptable_filter vfio_pci vfio_iommu_type1 vfio bridge stp llc dm_mirror dm_region_hash dm_log dm_mod iTCO_wdt iTCO_vendor_support vfat fat skx_edac edac_core coretemp intel_rapl iosf_mbi kvm_intel kvm irqbypass crc32_pclmul ghash_clmulni_intel aesni_intel lrw gf128mul glue_helper ablk_helper cryptd ses igb enclosure scsi_transport_sas pcspkr sg i2c_algo_bit dca joydev mei_me i2c_i801 shpchp i2c_core lpc_ich mei nfit libnvdimm acpi_power_meter acpi_cpufreq nfsd auth_rpcgss nfs_acl lockd
[Thu Nov  5 16:44:42 2020]  grace sunrpc ip_tables ext4 mbcache jbd2 sd_mod crc_t10dif crct10dif_generic ahci libahci crct10dif_pclmul crct10dif_common i40e libata crc32c_intel megaraid_sas ptp pps_core
[Thu Nov  5 16:44:42 2020] CPU: 45 PID: 0 Comm: swapper/45 Not tainted 3.10.0-693.el7.x86_64 #1
[Thu Nov  5 16:44:42 2020] Hardware name: Huawei 2288H V5/BC11SPSCB0, BIOS 6.58 03/30/2019
[Thu Nov  5 16:44:42 2020]  ffff885f7a343d88 428095446c04f372 ffff885f7a343d38 ffffffff816a3d91
[Thu Nov  5 16:44:42 2020]  ffff885f7a343d78 ffffffff810879c8 0000012c7a35a900 000000000000002c
[Thu Nov  5 16:44:42 2020]  ffff880063c78000 0000000000000080 ffff880063c89f40 000000000000002d
[Thu Nov  5 16:44:42 2020] Call Trace:
[Thu Nov  5 16:44:42 2020]  <IRQ>  [<ffffffff816a3d91>] dump_stack+0x19/0x1b
[Thu Nov  5 16:44:42 2020]  [<ffffffff810879c8>] __warn+0xd8/0x100
[Thu Nov  5 16:44:42 2020]  [<ffffffff81087a4f>] warn_slowpath_fmt+0x5f/0x80
[Thu Nov  5 16:44:42 2020]  [<ffffffff815af3e2>] dev_watchdog+0x242/0x250
[Thu Nov  5 16:44:42 2020]  [<ffffffff815af1a0>] ? dev_deactivate_queue.constprop.33+0x60/0x60
[Thu Nov  5 16:44:42 2020]  [<ffffffff81097316>] call_timer_fn+0x36/0x110
[Thu Nov  5 16:44:42 2020]  [<ffffffff815af1a0>] ? dev_deactivate_queue.constprop.33+0x60/0x60
[Thu Nov  5 16:44:42 2020]  [<ffffffff8109982d>] run_timer_softirq+0x22d/0x310
[Thu Nov  5 16:44:42 2020]  [<ffffffff81090b3f>] __do_softirq+0xef/0x280
[Thu Nov  5 16:44:42 2020]  [<ffffffff816b6a5c>] call_softirq+0x1c/0x30
[Thu Nov  5 16:44:42 2020]  [<ffffffff8102d3c5>] do_softirq+0x65/0xa0
[Thu Nov  5 16:44:42 2020]  [<ffffffff81090ec5>] irq_exit+0x105/0x110
[Thu Nov  5 16:44:42 2020]  [<ffffffff816b76c2>] smp_apic_timer_interrupt+0x42/0x50
[Thu Nov  5 16:44:42 2020]  [<ffffffff816b5c1d>] apic_timer_interrupt+0x6d/0x80
[Thu Nov  5 16:44:42 2020]  <EOI>  [<ffffffff816ab4a6>] ? native_safe_halt+0x6/0x10
[Thu Nov  5 16:44:42 2020]  [<ffffffff816ab33e>] default_idle+0x1e/0xc0
[Thu Nov  5 16:44:42 2020]  [<ffffffff81035006>] arch_cpu_idle+0x26/0x30
[Thu Nov  5 16:44:42 2020]  [<ffffffff810e7bca>] cpu_startup_entry+0x14a/0x1c0
[Thu Nov  5 16:44:42 2020]  [<ffffffff81051af6>] start_secondary+0x1b6/0x230
[Thu Nov  5 16:44:42 2020] ---[ end trace 3ee13723496196b6 ]---
```

这个堆栈表明宿主机的 eno3 网卡的 44 队列传送数据超时，非常值得怀疑。

## 宿主机 eno3 接口相关信息收集

经过上面的排查，问题指向 eno3 网卡的 44 队列，在进一步确认问题前，首先收集如下信息：

1. 网卡型号信息
```bash
    [localhost ~]$ lspci |grep Eth
    1a:00.0 Ethernet controller: Intel Corporation Ethernet Connection X722 for 10GbE SFP+ (rev 09)
    1a:00.1 Ethernet controller: Intel Corporation Ethernet Connection X722 for 10GbE SFP+ (rev 09)
    1a:00.2 Ethernet controller: Intel Corporation Ethernet Connection X722 for 1GbE (rev 09)
    1a:00.3 Ethernet controller: Intel Corporation Ethernet Connection X722 for 1GbE (rev 09)
    af:00.0 Ethernet controller: Intel Corporation I350 Gigabit Network Connection (rev 01)
    af:00.1 Ethernet controller: Intel Corporation I350 Gigabit Network Connection (rev 01)
    [localhost ~]$ 
```
2. 网卡驱动与固件相关信息

```bash
    [localhost ~]$ ethtool -i eno3
    driver: i40e
    version: 1.6.27-k
    firmware-version: 3.33 0x80000f09 255.65535.255
    expansion-rom-version: 
    bus-info: 0000:1a:00.2
    supports-statistics: yes
    supports-test: yes
    supports-eeprom-access: yes
    supports-register-dump: yes
    supports-priv-flags: yes
```

3. 网卡 up 与其它状态信息

```bash
    [localhost ~]$ ethtool eno3
    Settings for eno3:
            Supported ports: [ TP ]
            Supported link modes:   1000baseT/Full 
            Supported pause frame use: Symmetric
            Supports auto-negotiation: Yes
            Advertised link modes:  1000baseT/Full 
            Advertised pause frame use: No
            Advertised auto-negotiation: Yes
            Speed: 1000Mb/s
            Duplex: Full
            Port: Twisted Pair
            PHYAD: 0
            Transceiver: external
            Auto-negotiation: on
            MDI-X: Unknown
    Cannot get wake-on-lan settings: Operation not permitted
            Current message level: 0x00000007 (7)
                                   drv probe link
            Link detected: yes
```

4. 针对 44 队列查看统计信息的变化情况

```bash
    [localhost ~]$ ethtool -S eno3 | grep 44\.
         tx-44.tx_packets: 222225
         tx-44.tx_bytes: 19784930
         rx-44.rx_packets: 49882
         rx-44.rx_bytes: 3308092
    [localhost ~]$ ethtool -S eno3 | grep 44\.
         tx-44.tx_packets: 222231
         tx-44.tx_bytes: 19785726
         rx-44.rx_packets: 49882
         rx-44.rx_bytes: 3308092
    [localhost ~]$ ethtool -S eno3 | grep 44\.
         tx-44.tx_packets: 222238
         tx-44.tx_bytes: 19786584
         rx-44.rx_packets: 49882
         rx-44.rx_bytes: 3308092
    [localhost ~]$ ethtool -S eno3 | grep 44\.
         tx-44.tx_packets: 222239
         tx-44.tx_bytes: 19786626
         rx-44.rx_packets: 49882
         rx-44.rx_bytes: 3308092
    [localhost ~]$ ethtool -S eno3 | grep 44\.
         tx-44.tx_packets: 222240
         tx-44.tx_bytes: 19786668
         rx-44.rx_packets: 49882
         rx-44.rx_bytes: 3308092
```

从上面的几次的统计信息可以发现，tx 的数据有在增加，rx 一直没有增加，与宿主机打印的堆栈联系到一起看，确定这个**队列的接收异常**了。

## 网上搜索相关的内容

网上搜索发现有相关问题的帖子，其中有提到在使用 DCB 的时候出现了问题，查看宿主机的 CONFIG_DCB 配置，确定出问题机器的内核确实开启了这个功能，相关信息如下：


```bash
[localhost ~]$ grep 'DCB' /boot/config-3.10.0-693.el7.x86_64 
CONFIG_DCB=y
```

进一步的搜索找到了如下 patch 链接：

[i40e/i40evf: Detect and recover hung queue scenario](https://lists.osuosl.org/pipermail/intel-wired-lan/Week-of-Mon-20171218/011054.html)

首先确定这个 patch 与宿主机 transmit queue timeout 的问题一致，然后需要确定如何处理这个 patch，是直接合入吗？

根据经验，我认为可以先看看高版本的 i40e 驱动是否已经合入了这个 patch，于是下载 i40e-2.13.10 驱动。

下载后并不着急先对比，而是先在宿主机上编译一下，确定能够编译通过后，开始对比代码，确认此 patch 已经合入，同时翻了下 i40e 驱动不同版本的 release notes，有找到类似的 tx timeout 问题。

## 给宿主机 centos 系统升级 i40e 驱动

完成了上面的过程后，明确需要通过升级 i40e 驱动来解决，这样就需要**确定升级的方案。**

那么升级后，**该怎样确定升级生效呢？**

这其实可以通过 **ethtool -i eno3** 获取驱动的版本号来检查。

下面是具体的升级方案与测试过程：

1. 替换 /lib/modules/xx 下的 i40e.ko.xz 文件

    重启宿主机后发现仍旧用的是旧的 i40e 驱动，确认内核的 config 文件中 i40e 是配置为了模块，那看来应该是 initrd 中加载的。


2. 修改 centos 的 initrd

    查看 /boot 目录以及 grub 的配置文件，确定 centos 并没有使用 initrd，而是使用了 initramfs。按照常规的方法解压这个 initramfs 文件，没有找到相关的驱动，不过我发现解压出来的东西的大小远小于 initramfs 文件的大小。
    
**全局 find 没有找到其它路径存在的 i40e 相关的 ko 文件**，看来还得搞搞 initramfs。

### cenots 的 initramfs 的机关

一通研究与求助后发现 centos 的 initramfs 与常规的 initrd 的解压过程并不相同，csdn 中找到了如下链接说明这个过程。

[centos7 initramfs解包打包](https://blog.csdn.net/a363344923/article/details/99851657)

具体的步骤从上述链接中摘录到下面以记录：

解包过程：

```basj
cd /boot
initramfs=$(ls -a initramfs-$(uname -r).img)
cp /boot/$initramfs /tmp

mkdir -p /tmp/early_cpio
mkdir -p /tmp/rootfs_cpio

#解包early_cpio
cd /tmp/early_cpio
cpio -idm < ../$initramfs

#解包rootfs
cd /tmp/rootfs_cpio
/usr/lib/dracut/skipcpio ../$initramfs | zcat | cpio -id
```

重新打包过程：

```bash
cd /tmp/early_cpio
find . -print0 | cpio --null -o -H newc --quiet >../early_cpio.img

cd /tmp/rootfs_cpio
find . | cpio -o -H newc | gzip > ../rootfs_cpio.img

cd /tmp
cat early_cpio.img rootfs_cpio.img > newInitramfs.img
```

使用上面的步骤操作后重新替换并备份 initramfs 后重启宿主机，重启后查看驱动的版本，确定升级成功。

## strip 驱动引入的问题
上面的操作尽管已经成功，但是我们注意到**编译出来的 i40e 驱动的大小是原驱动的几十倍。**

为了减少大小，我直接执行 **strip i40e.ko** 操作，操作后发现大小基本上与原驱动一样了，重新替换后重启系统，发现 i40e 驱动加载失败。

dmesg 中有如下信息：

```
[74970.382378] i40e: module has no symbols (stripped?)
```
看来应该是 strip 的问题，strip 将一些模块加载依赖的符号移除了，故而模块不能正常加载。

网上搜索了下，发现可以使用 strip 命令的 **-d** 选项让 strip **只移除调试符号**，执行了这个操作后发现 ko 文件的大小要比原来的大一些，但不超过 1 倍，同时也能够正常加载了。

## 部署中遇到的问题

在本地测试没有问题后，开始部署到前厂的设备上，**使用同一个 initramfs 替换 /boot 并备份旧的 initramfs 到 /root/ 目录中，然后重启设备。**

重启后发现系统进入了**救援模式**，这下尴尬了！

尝试 mount 磁盘，结果都失败了，报的错都是 unknown ext4 fs 这种，**查看 /proc/filesystems 发现这个救援模式的内核只支持虚拟的文件系统**，压根就不支持 ext4、vfat 这些文件系统，看来这个方法行不通。

此时 i40e 驱动倒是正常加载起来了，网口可以用，但是无法挂载磁盘即便我从网络下载到一个其它设备上的 initramfs 也修改不了，这可怎么半捏？

求助了下对引导这块非常熟悉的同事，得到反馈说也许可以通过 efi shell 来将 initramfs 还原，进入选择引导项的界面后发现这个方式不可用。

### 修改 grub 的引导参数
上面的尝试都失败后，我想到也许可以通过修改 grub 的引导参数来使用备份的 initramfs 文件以恢复系统。

具体操作步骤如下：

1. 在 grub 页面按 c 进入到 grub 命令行界面
2. 使用 ls 来找到备份的 initramfs 文件的位置，找到后记录全路径
3. 按 esc，返回 grub 选择界面，按 e 进入 grub 编辑界面
4. 找到 initrd 的配置内容，修改 initramfs 的路径
5. 按 Ctrl + x 或 F10 引导

grub 查找文件的过程截图如下：

![在这里插入图片描述](https://img-blog.csdnimg.cn/2020111512082832.png#pic_center)
grub 能够识别常见的文件系统，上面 (hd0，msdos1) 代表的是一个具体的分区，可以执行 ls 命令来确定具体的位置。

这里我使用我的虚拟机中的 initrd 文件来模拟，initramfs 的操作过程类似。

找到后返回到 grub 引导页面，编辑 grub 配置，修改 initrd 的配置内容，示例图片如下：

![grub-initrd](https://img-blog.csdnimg.cn/20201115121224313.png#pic_center)
修改后，按 Ctrl + x 引导后能够成功进入系统。

### 问题出在哪里？
进入系统后，并不着急恢复 initramfs，而是先看看问题出在哪里。对比 md5sum 发现前场设备旧的 initramfs 文件与本地测试机器上的旧 initramfs 文件 **md5sum 不同**。

尽管已经找到了这个问题，但是这个问题让我们觉的这种升级方式可能不靠谱，需要考虑其它的方式。

最终确定首先替换 /lib/modules 中的 ko 文件，然后在 **/etc/rc.local** 中移除现有的驱动，然后重新加载。

测试发现这样的过程存在一个问题——移除驱动重新加载后接口是 down 的，需要添加 up 操作的逻辑。

到这里，这个问题得到了解决。

## 总结
对于这个问题，我有下面这些疑问：

为什么虚拟机使用宿主机的 enos3 的 44 队列收发包呢？这个是固定的还是随机的？是 qemu 运行时指定的，还是系统按照某种规则分配的呢？

希望有一天能够回答这个问题。

同时也必须指出，在替换 initramfs、bzImage 这些重要的文件前**一定要进行备份**，不然可能会导致灾难性的后果。

如果有备份，但是不在目标机器上，可以使用 u 盘制作一个发行版的 live 系统，将备份文件拷贝到 u 盘的分区中，然后使用 u 盘引导进入 live 系统，挂载目标机器的磁盘还原文件。


