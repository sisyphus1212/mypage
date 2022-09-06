# 编译dpdk-19.10时遇到的问题
## 未安装 numa 库的问题
```make
/home/longyu/dpdk-19.08/lib/librte_eal/linux/eal/eal_memory.c:32:10: fatal error: numa.h: No such file or directory
 #include <numa.h>
```

官方网页中的相关说明内容如下：


> Library for handling NUMA (Non Uniform Memory Access).
>    numactl-devel in Red Hat/Fedora;
 >   libnuma-dev in Debian/Ubuntu;

我是在 Debian 系统中编译，需要安装 libnuma-dev 库，安装示例如下：

```sh
longyu@longyu-pc:~/dpdk-19.08$ sudo apt-get install libnuma-dev
```

## 加载编译出的内核模块
加载 igb_uio 之前需要先加载 uio 内核模块。uio 模块一般都已经安装到了系统中的 /usr/lib/modules/$(uname -r)/ 目录中，只是一般没有被使用，这里可以通过 modprobe uio 直接加载此内核模块。

## 编译 examples 目录下的 demo
1. 检查 RTE_SDK 与 RTE_TARGET 环境变量是否设定

	```sh
	longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ echo -e  $RTE_SDK "\n" $RTE_TARGET
	/home/longyu/dpdk-19.08 
	 x86_64-native-linuxapp-gcc
	```
	**注意这里的 RTE_SDK 为 dpdk 源码的根目录，RTE_RARGET 为编译的目标设备全名。**

2. 编译 examples 目录下的 helloworld demo

	进入到 helloworld 子目录中，执行 make 命令，输出报错信息如下：

	```sh
	longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ make 
	/bin/sh: 1: pkg-config: not found
	/home/longyu/dpdk-19.08/mk/internal/rte.extvars.mk:29: *** Cannot find .config in /home/longyu/dpdk-19.08/x86_64-native-linuxapp-gcc.  Stop.
	longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ echo $RTE_SDK
	/home/longyu/dpdk-19.08
	```

	**解决 pkg-config not found 的问题**

	```sh
	# 查看文件是否存在
	longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ sudo updatedb
	longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ locate 'pkg-config'
	/etc/dpkg/dpkg.cfg.d/pkg-config-hook-config
	/var/cache/apt/archives/pkg-config_0.29-6_amd64.deb
	/var/lib/dpkg/info/pkg-config.list
	
	# 文件不存在则安装
	longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ sudo apt-get install pkg-config
	
	# 存在则检查环境变量配置
	```
	**解决找不到 .config 文件的问题**
	
	```sh
	longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ make
	/home/longyu/dpdk-19.08/mk/internal/rte.extvars.mk:29: *** Cannot find .config in /home/longyu/dpdk-19.08/x86_64-native-linuxapp-gcc.  Stop.
	```

	如果编译时有上面的错误，那么你需要检查编译出的目标与 RTE_TARGET 变量设定的是否一致。
	
  3. 编译成功的输出

		```sh
		longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ make
		  CC main.o
		  LD helloworld
		  INSTALL-APP helloworld
		  INSTALL-MAP helloworld.map
		longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ ls ./build/helloworld
		./build/helloworld
		```

    4. 执行 helloworld 时程序 panic 
	
		我在执行 helloworld 程序时遇到了如下错误：
	
		```sh
		longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ sudo ./build/helloworld
		EAL: Detected 2 lcore(s)
		EAL: Detected 1 NUMA nodes
		EAL: Multi-process socket /var/run/dpdk/rte/mp_socket
		EAL: Selected IOVA mode 'PA'
		EAL: No free hugepages reported in hugepages-2048kB
		EAL: No available hugepages reported in hugepages-2048kB
		EAL: No available hugepages reported in hugepages-1048576kB
		EAL: FATAL: Cannot get hugepage information.
		EAL: Cannot get hugepage information.
		PANIC in main():
		Cannot init EAL
		5: [./build/helloworld(_start+0x2a) [0x55d9e3802e3a]]
		4: [/lib/x86_64-linux-gnu/libc.so.6(__libc_start_main+0xeb) [0x7fa75466d09b]]
		3: [./build/helloworld(+0xa9e0c) [0x55d9e364ee0c]]
		2: [./build/helloworld(__rte_panic+0xba) [0x55d9e365f480]]
		1: [./build/helloworld(rte_dump_stack+0x1b) [0x55d9e38dfa7b]]
		Aborted
		```

   		从上面的输出中我发现是 hugepage 相关的问题，浏览官方网页文档，我执行了下面的操作：
		
		```sh	
		longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ sudo su -c 'echo 128 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'
		```
		这之后我重新执行 helloworld 程序，得到的输出如下：
		```sh
		longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ sudo ./build/helloworld
		EAL: Detected 2 lcore(s)
		EAL: Detected 1 NUMA nodes
		EAL: Multi-process socket /var/run/dpdk/rte/mp_socket
		EAL: Selected IOVA mode 'PA'
		EAL: No available hugepages reported in hugepages-1048576kB
		EAL: Probing VFIO support...
		EAL: WARNING: cpu flags constant_tsc=yes nonstop_tsc=no -> using unreliable clock cycles !
		EAL: PCI device 0000:00:03.0 on NUMA socket -1
		EAL:   Invalid NUMA socket, default to 0
		EAL:   probe driver: 8086:100e net_e1000_em
		hello from core 1
		hello from core 0
		longyu@longyu-pc:~/dpdk-19.08/examples/helloworld$ 
		```
	
	 	尽管执行了上面的操作之后，helloworld 能够正常执行，但是对于上述操作背后涉及的东西我却没有进一步的认识，这有待我对 dpdk 的进一步研究。 	

## 绑定网络端口到内核模块的问题
1. lspci not found 的问题

	绑定网络端口到内核模块时有如下报错信息：
	
	```sh
	longyu@longyu-pc:~/dpdk-19.08$ sudo ./usertools/dpdk-devbind.py --bind=igb_uio ens33
	'lspci' not found - please install 'pciutils'
	```
	根据提示信息执行如下命令，安装 pciutils。
	
	```sh
	longyu@longyu-pc:~/dpdk-19.08$ sudo apt-get install pciutils
	```
2. 接口正在使用导致绑定端口失败的问题

	解决了 lspci 命令找不到的问题之后我重新执行绑定端口的命令，有如下输出：

	```sh	
	longyu@longyu-pc:~/dpdk-19.08$ sudo ./usertools/dpdk-devbind.py --bind=igb_uio ens3
	Warning: routing table indicates that interface 0000:00:03.0 is active. Not modifying
	```
	从上面的输出中，我确定绑定端口失败了，我望文生义的抓住了 routing table 这个名词，觉得应该清除路由表的内容，在网上搜了一下没有发现该如何去做。这之后我想起了 TCP/IP 协议栈中对关闭网络设备的描述，记得在关闭网络设备的时候会清空路由表。基于这样的认识，我执行了如下命令 down 掉待使用的网络设备：

	```sh
	longyu@longyu-pc:~/dpdk-19.08$ sudo ifconfig ens3 down
	```

	 执行了这一步后我发现 ssh 连接异常了，这才让我意识到我就是通过这个网卡设备连接到虚拟机中的，关闭了设备之后网络断开，ssh 就失效了。
	
	这个问题的解决方法如下：
	
	> 在虚拟机中添加两块网卡，一块用于正常的连接，一块用于测试。

## 执行 testpmd 测试程序
指定如下参数，执行 testpmd 命令。

```sh
longyu@longyu-pc:~/dpdk-19.08/x86_64-native-linux-gcc/app$ sudo ./testpmd -l 0-1 -n 1 -- -i --portmask=0x1 --nb-cores=1
```

以上参数需要根据执行的环境进行修改！

查看端口信息：

```sh
testpmd> show port info 0

********************* Infos for port 0  *********************
MAC address: 52:54:00:CE:BA:AD
Device name: 0000:00:03.0
Driver name: net_e1000_em
Connect to socket: 0
memory allocation on the socket: 0
Link status: up
Link speed: 1000 Mbps
Link duplex: full-duplex
MTU: 1500
Promiscuous mode: enabled
Allmulticast mode: disabled
Maximum number of MAC addresses: 15
Maximum number of MAC addresses of hash filtering: 0
VLAN offload: 
  strip off 
  filter off 
  qinq(extend) off 
No RSS offload flow type is supported.
Minimum size of RX buffer: 256
Maximum configurable length of RX packet: 16128
Current number of RX queues: 1
Max possible RX queues: 1
Max possible number of RXDs per queue: 4096
Min possible number of RXDs per queue: 32
RXDs number alignment: 8
Current number of TX queues: 1
Max possible TX queues: 1
Max possible number of TXDs per queue: 4096
Min possible number of TXDs per queue: 32
TXDs number alignment: 8
Max segment number per packet: 255
Max segment number per MTU/TSO: 255
```

## 总结
**编译 latest dpdk 的过程中会遇到很多的问题，一些问题是因为缺少必要的库与工具所致，一些问题是对某些功能的工作原理不清楚所致，最终这些问题得到了解决。在解决问题的过程中也体现出了我对 linux 中的一些基础知识有了陌生感，需要及时的复习复习。**

**下面是我对 dpdk 的一些认识：**

**dpdk 依赖 uio 内核模块来将网络设备映射到用户空间，通过重新绑定网络设备驱动到 pmd 来构建从用户空间操作网络设备的桥梁。这里的 pmd 全称为 polling mode driver，它来源于驱动设计模型中的轮询模型。**

**dpdk 使用 pmd 来拦截网络设备的硬件中断，这是轮询式数据处理的基础，也是 dpdk 所要解决的一大难题。**

