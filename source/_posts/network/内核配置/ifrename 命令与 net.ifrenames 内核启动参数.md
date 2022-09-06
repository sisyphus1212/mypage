# ifrename 命令与 net.ifrenames 内核启动参数
很多网卡驱动在加载时会对虚拟网络接口的名称进行重命名。下面是我的系统上 dmesg 中的部分输出，可以看到最开始虚拟网络接口的名称为 eth0，最后一行的信息中可以看到接口名称被改为了 enp2s0。

```
[    4.218735] r8169 0000:02:00.0 eth0: RTL8168h/8111h, 80:e8:2c:17:f0:77, XID 54100880, IRQ 126
[    4.218736] r8169 0000:02:00.0 eth0: jumbo features [frames: 9200 bytes, tx checksumming: ko]
[    4.219142] xhci_hcd 0000:00:14.0: hcc params 0x200077c1 hci version 0x110 quirks 0x0000000000009810
[    4.219146] xhci_hcd 0000:00:14.0: cache line size of 64 is not supported
[    4.219322] usb usb1: New USB device found, idVendor=1d6b, idProduct=0002, bcdDevice= 4.19
[    4.219324] usb usb1: New USB device strings: Mfr=3, Product=2, SerialNumber=1
[    4.219325] usb usb1: Product: xHCI Host Controller
[    4.219326] usb usb1: Manufacturer: Linux 4.19.0-9-amd64 xhci-hcd
[    4.219327] usb usb1: SerialNumber: 0000:00:14.0
[    4.219435] hub 1-0:1.0: USB hub found
[    4.219456] hub 1-0:1.0: 12 ports detected
[    4.220818] r8169 0000:02:00.0 enp2s0: renamed from eth0
```
一般来说上述行为并没有啥影响，但在特定的业务场景下可能需要禁止这种行为。要禁止这种行为，可以通过设定 linux 内核启动参数 net.ifrenames 来实现。

设定 net.ifrenames=0 ，表示不对 netdev 重命名，这样网络接口名称将会保持 eth0、eth1 这种模式的名字。

## 如何动态修改 netdev name
一些系统中，有根据网口的不同功能重命名 netdev 的需求。这可以通过调用 ifrename 命令来完成。这个命令在我的系统中并没有安装，我首先执行如下命令，搜索需要安装的程序名。

```bash
[longyu@debian-10:22:10:50] ~ $ sudo apt-cache search ifrename
ifrename - Rename network interfaces based on various static criteria
```
从上面的输出中，我确定需要安装的程序名就是 ifrename。执行如下命令安装 ifrename 命令。

```bash
[longyu@debian-10:22:11:07] ~ $ sudo apt-get install ifrename
正在读取软件包列表... 完成
正在分析软件包的依赖关系树       
正在读取状态信息... 完成       
下列【新】软件包将被安装：
  ifrename
升级了 0 个软件包，新安装了 1 个软件包，要卸载 0 个软件包，有 67 个软件包未被升级。
需要下载 53.9 kB 的归档。
解压缩后会消耗 128 kB 的额外空间。
获取:1 https://mirrors.tuna.tsinghua.edu.cn/debian buster/main amd64 ifrename amd64 30~pre9-13 [53.9 kB]
已下载 53.9 kB，耗时 4秒 (13.2 kB/s)
正在选中未选择的软件包 ifrename。
(正在读取数据库 ... 系统当前共安装有 354686 个文件和目录。)
准备解压 .../ifrename_30~pre9-13_amd64.deb  ...
正在解压 ifrename (30~pre9-13) ...
正在设置 ifrename (30~pre9-13) ...
invoke-rc.d: policy-rc.d denied execution of start.
正在处理用于 systemd (241-7~deb10u4) 的触发器 ...
正在处理用于 man-db (2.8.5-2) 的触发器 ...
```
安装成功后，man ifrename 查看如何使用这个命令。下面是 man ifrename 的部分输出。

```
      ifrename [-c configfile] [-p] [-d] [-u] [-v] [-V] [-D] [-C]
       ifrename [-c configfile] [-i interface] [-n newname]
```
注意 ifrename 必须在接口被 up 之前执行，不能对一个 up 的接口执行 ifrename 操作，可以将这样的行为理解为，在 up 的时候 ifrename 被引用。这表明 down 掉接口就可以修改名字了。

一个具体的示例如下：

```bash
[longyu@debian-10:22:41:28] arm64 $ sudo /sbin/ifconfig enp2s0 down
[longyu@debian-10:22:41:32] arm64 $ sudo ifrename -i enp2s0 -n eth0
eth0
[longyu@debian-10:22:41:45] arm64 $ /sbin/ifconfig eth0
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

