---
title: linux 网卡命名
date: 2022-08-27 16:04:02
index_img: https://www.dpdk.org/wp-content/uploads/sites/35/2021/03/DPDK_logo-01-1.svg
categories:
- [linux,网络开发,网卡驱动]
tags:
 - linux
 - 网卡驱动
 - kernel
---

# ifrename网卡重命名
## ifrename 命令与 net.ifrenames 内核启动参数
很多网卡驱动在加载时会对虚拟网络接口的名称进行重命名。下面是我的系统上 dmesg 中的部分输出，可以看到最开始虚拟网络接口的名称为 eth0，最后一行的信息中可以看到接口名称被改为了 enp2s0。

```
[    4.218735] r8169 0000:02:00.0 eth0: RTL8168h/8111h, 30:88:2c:17:55:d7, XID 54100880, IRQ 126
[    4.218736] r8169 0000:02:00.0 eth0: jumbo features [frames: 9200 bytes, tx checksumming: ko]
[    4.219142] xhci_hcd 0000:00:14.0: hcc params 0x200077c1 hci version 0x110 quirks 0x0000000000009810
[    4.219435] hub 1-0:1.0: USB hub found
[    4.219456] hub 1-0:1.0: 12 ports detected
[    4.220818] r8169 0000:02:00.0 enp2s0: renamed from eth0
```
一般来说上述行为并没有啥影响，但在特定的业务场景下可能需要禁止这种行为。要禁止这种行为，可以通过设定 linux 内核启动参数 net.ifrenames 来实现。

设定 net.ifrenames=0 ，表示不对 netdev 重命名，这样网络接口名称将会保持 eth0、eth1 这种模式的名字。

## 如何动态修改 netdev name
一些系统中，有根据网口的不同功能重命名 netdev 的需求。这可以通过调用 ifrename 命令来完成。这个命令在我的系统中并没有安装，我首先执行如下命令，搜索需要安装的程序名。

```bash
[sisyphus@ubuntu] ~ $ sudo apt-cache search ifrename
ifrename - Rename network interfaces based on various static criteria
```
从上面的输出中，我确定需要安装的程序名就是 ifrename。执行如下命令安装 ifrename 命令。

```bash
[sisyphus@ubuntu] ~ $ sudo apt-get install ifrename
```
安装成功后，man ifrename 查看如何使用这个命令。下面是 man ifrename 的部分输出。

```
      ifrename [-c configfile] [-p] [-d] [-u] [-v] [-V] [-D] [-C]
       ifrename [-c configfile] [-i interface] [-n newname]
```
注意 ifrename 必须在接口被 up 之前执行，不能对一个 up 的接口执行 ifrename 操作，可以将这样的行为理解为，在 up 的时候 ifrename 被引用。这表明 down 掉接口就可以修改名字了。

一个具体的示例如下：

```bash
[sisyphus@ubuntu] arm64 $ sudo /sbin/ifconfig enp2s0 down
[sisyphus@ubuntu] arm64 $ sudo ifrename -i enp2s0 -n eth0
eth0
[sisyphus@ubuntu] arm64 $ /sbin/ifconfig eth0
eth0: flags=4098<BROADCAST,MULTICAST>  mtu 1500
        ether 80:e8:2c:17:f0:77  txqueuelen 1000  (Ethernet)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
```
在上面的示例中，我首先使用 ifconfig down 掉接口，然后执行 ifrename 将网络接口名称从 enp2s0 修改为 eth0，这之后 ifconfig eth0 查看接口信息确认修改成功。

这时候查看 dmesg 的输出信息，发现有下面的输出：

```
[ 4288.006591] r8169 0000:02:00.0 eth0: renamed from enp2s0
```
使用 strace 命令查看系统调用过程，发现核心的过程在于下面两个系统调用：

```
socket(AF_INET, SOCK_DGRAM, IPPROTO_IP) = 3
ioctl(3, SIOCSIFNAME, {ifr_name="eth0", ifr_newname="enp2s0"}) = 0
```
上面的两个系统调用首先执行 socket 打开一个网络设备，然后通过 ioctl 命令来修改网络设备的配置。

内核里面的流程如下所示：

```
sock_ioctl -> sock_do_ioctl -> dev_ioctl -> dev_ifsioc -> dev_change_name
```
最终是通过调用 dev_change_name 函数来完成虚拟网卡接口重命名的。

# udev 重命名网卡
当前网卡的命名方式可以通过proc文件查看，比如网卡ens160，命名方式为4，即对应内核中的NET_NAME_RENAMED，表示网卡名是被用户空间程序修改的：
```bash
# cat /sys/class/net/ens160/name_assign_type
4

#define NET_NAME_ENUM       1   /* enumerated by kernel */
#define NET_NAME_PREDICTABLE    2   /* predictably named by the kernel */
#define NET_NAME_USER       3   /* provided by user-space */
#define NET_NAME_RENAMED    4   /* renamed by user-space */
```

## systemd.link — 底层物理网络设备配置

参考:[http://www.jinbuguo.com/systemd/systemd.link.html]
在用户空间，默认情况下ubuntu会根据systemd目录下的link文件命名网卡，NamePolicy变量指定了5中命名策略：kernel database onboard slot path，优先级由高到低排列。

```bash
# cat /lib/systemd/network/99-default.link
[Link]
NamePolicy=kernel database onboard slot path
MACAddressPolicy=persistent
```

### udevadm 命令查看生效规则
```bash
$ udevadm info -e | grep ens160
P: /devices/pci0000:00/0000:00:15.0/0000:03:00.0/net/ens160
E: DEVPATH=/devices/pci0000:00/0000:00:15.0/0000:03:00.0/net/ens160
E: ID_NET_NAME_SLOT=ens160
```

## MACAddressPolicy

应该如何设置网卡的MAC地址：

“persistent”

如果内核使用了网卡硬件固有的MAC地址(绝大多数网卡都有)， 那么啥也不做，直接使用内核的MAC地址。 否则，将会随机新生成一个 确保在多次启动之间保持固定不变的MAC地址(针对给定的主板与网卡)。 自动生成MAC地址的特性 要求网卡必须存在 ID_NET_NAME_* 属性， 否则无法自动生成MAC地址。

“random”

如果内核使用了随机生成的MAC地址(而不是网卡硬件固有的MAC地址)， 那么啥也不做，直接使用内核的MAC地址。 否则，将在网卡每次出现的时候(一般在启动过程中)随机新生成一个MAC地址。 无论使用上述哪种方式生成的MAC地址， 都将设置 “unicast” 与 “locally administered” 位。

“none”

无条件的直接使用内核的MAC地址。

MACAddress

在未设置 “MACAddressPolicy=” 时所使用MAC地址。

另外，Link小节中，我们必须为某个网卡进行命名，因此肯定会有 NamePolicy 或者 Name 选项

## NamePolicy

应该如何设置网卡的名称， 仅在未使用 “net.ifnames=0″ 内核引导选项时有意义。 接受一个空格分隔的策略列表， 顺序尝试每个策略，并以第一个成功的策略为准。 所得的名字将被用于设置网卡的 “ID_NET_NAME” 属性。 注意，默认的udev规则会用 “ID_NET_NAME” 的值设置 “NAME” 属性(也就是网卡的名称)。 如果网卡已经被空户空间命名，那么将不会进行任何重命名操作。 可用的策略如下：

“kernel”

如果内核已经为此网卡设置了固定的可预测名称， 那么不进行任何重命名操作。

“database”

基于网卡的 “ID_NET_NAME_FROM_DATABASE” 属性值(来自于udev硬件数据库)设置网卡的名称。

“onboard”

基于网卡的 “ID_NET_NAME_ONBOARD” 属性值(来自于板载网卡固件)设置网卡的名称。

“slot”

基于网卡的 “ID_NET_NAME_SLOT” 属性值(来自于可插拔网卡固件)设置网卡的名称。

“path”

基于网卡的 “ID_NET_NAME_PATH” 属性值(来自于网卡的总线位置)设置网卡的名称。

“mac”

基于网卡的 “ID_NET_NAME_MAC” 属性值(来自于网卡的固定MAC地址)设置网卡的名称。

Name

在 NamePolicy= 无效时应该使用的网卡名称。 无效的情况包括： (1)未设置 NamePolicy= ； (2)NamePolicy= 中的策略全失败； (3)使用了”net.ifnames=0″内核引导选项

注意， 千万不要设置可能被内核用于其他网口的名称(例如 “eth0″)， 这可能会导致 udev 在分配名称时与内核产生竞争， 从而导致不可预期的后果。 最好的做法是使用一些永远不会导致冲突名称或前缀，例如： “internal0″”external0″ 或 “lan0″”lan1″/”lan3″

## 根据udev规则来rename
1. udev 辅助工具程序 /lib/udev/rename_device 会根据 /usr/lib/udev/rules.d/60-net.rules 中的指示去查询 /etc/sysconfig/network-script/ifcfg-IFACE 配置文件，根据HWADDR 读取设备名称
2. biosdevname 根据 /user/lib/udev/rules.d/71-boosdevname.rules
通过检查网络接口设备，根据 /usr/lib/udev/rules.d/75-net-description 中 ID_NET_NAME_ONBOARD 和 ID_NET_NAME_SLOT,ID_NET_NAME_PATH 命名

## 使用 biosdevname 的一致网络设备命名
biosdevname 程序使用系统 BIOS 的信息，特别是类型 9 (System Slot) 和类型 41 （板设备扩展信息）字段包含在 SMBIOS 中。如果系统的 BIOS 没有 SMBIOS 版本 2.6 或更高版本，且此数据不会使用，则不会使用新的命名规则。大多数较旧的硬件不支持此功能，因为缺少包含正确的 SMBIOS 版本和字段信息的 BIOS。有关 BIOS 或 SMBIOS 版本信息，请联系您的硬件供应商
# GRUB_CMDLINE_LINUX配置网卡名
修改/etc/default/grub文件，在（GRUB_CMDLINE_LINUX=）一行增加参数：（net.ifnames=0 biosdevname=0）。之后允许update-grub命令更新grub启动配置文件。重新启动系统，网卡的命名恢复成ethx格式。
另外在文件/etc/network/interfaces中配置的网卡名称需要手动修改，把ens160相关的修改为ethx。
