# dpdk 程序绑不同的核性能有明显差异问题分析
## 前言
dpdk 程序会将**收发包线程绑定到指定的 cpu 核上**，在多核环境中执行就要配置需要使用的核。在性能测试的时候，发现当收发包线程绑定到 0 核、1 核对应的 cpu 上后，**性能会有明显的下降**，而绑定到 0 核、1 核之后的核上却没有这个问题。

在排查这个问题的时候发现，**系统中的一些中断只在 0 核上有统计计数**，表明其中断处理程序只在 0 核上执行，当 dpdk 程序也使用 0 核进行收发包的时候，这些中断处理程序就会与 dpdk 程序共享 cpu 核，从而导致 dpdk 程序性能下降。

在定位这个问题中，有对 irq smp_affinity 的设定过程，通过设定多个中断的 irq smp_affinity 让其在 0 核与 1 核之后的核上运行，重新测试后有明显的改善但是还是差一点，继续定位发现 0 核上有很多的 soft irq 程序在运行。

在本文中我将探讨一下 irq smp_affinity 的知识，同时引出 soft irq 的内容。

## 内核文档中与 irq smp_affinity 相关的信息
一手资料源自内核 Documentation 目录中，摘录如下：

```manual
================
SMP IRQ affinity
================
/proc/irq/IRQ#/smp_affinity and /proc/irq/IRQ#/smp_affinity_list specify
which target CPUs are permitted for a given IRQ source.  It's a bitmask
(smp_affinity) or cpu list (smp_affinity_list) of allowed CPUs.  It's not
allowed to turn off all CPUs, and if an IRQ controller does not support
IRQ affinity then the value will not change from the default of all cpus.

/proc/irq/default_smp_affinity specifies default affinity mask that applies
to all non-active IRQs. Once IRQ is allocated/activated its affinity bitmask
will be set to the default mask. It can then be changed as described above.
Default mask is 0xffffffff.

Here is an example of limiting that same irq (44) to cpus 1024 to 1031::

        [root@moon 44]# echo 1024-1031 > smp_affinity_list
        [root@moon 44]# cat smp_affinity_list
        1024-1031

Note that to do this with a bitmask would require 32 bitmasks of zero
to follow the pertinent one.
```
smp_affinity 设定了单个中断被允许执行的 cpu 掩码，内核会以中断号为标识符在 /proc/irq/ 为每一个中断创建一个子目录，我们可以通过读写 /proc/irq/IRQ 子目录中的文件来控制每一个中断允许被执行的 cpu 列表。

## 一个示例
这里我以 iwlwifi 无线网卡设备的中断来演示如何查看并修改 irq smp_affinity，达到让设定的中断服务程序在指定的 cpu 核上执行的目的。

首先通过访问 /proc/interrupts 确认 iwlwifi 的中断计数在增加，操作记录如下：


```bash
[longyu@debian-10:20:20:25] 14 $ grep '141:' /proc/interrupts 
 141:     486315          0          0     596832          0          0          0          0  IR-PCI-MSI 333824-edge      iwlwifi: default queue
[longyu@debian-10:20:21:07] 14 $ grep '141:' /proc/interrupts 
 141:     486405          0          0     596832          0          0          0          0  IR-PCI-MSI 333824-edge      iwlwifi: default queue
[longyu@debian-10:20:21:08] 14 $ grep '141:' /proc/interrupts 
 141:     486703          0          0     596832          0          0          0          0  IR-PCI-MSI 333824-edge      iwlwifi: default queue
```
上面的操作查了三次 141 号中断的统计计数，输出信息表明中断服务程序在 0 核上与 3 核上执行，141 号中断的 smp_affinity 内容如下：

```bash
[longyu@debian-10:20:27:01] 14 $ cat /proc/irq/141/smp_affinity
ff
```
从上面的内容可以确定，**141 号中断的中断服务程序被允许在前 8 个核上运行，但是中断统计计数的变化情况表明，它只在 0 核与 3 核上执行。**

下面我通过向 /proc/irq/141/smp_affinity 中写入值来修改中断的 cpu 亲和性，**指定只允许 141 中断服务程序在 4 核上运行。**

操作记录如下：
```bash
[longyu@debian-10:20:29:44] 14 $ su -c ' echo '10' > /proc/irq/141/smp_affinity'
密码：
[longyu@debian-10:20:29:56] 14 $ cat /proc/irq/141/smp_affinity
10
```
写入 proc 下的文件需要有 root 权限，**smp_affinity 是以十六进制的形式传递数据的，每一位表示一个 cpu 核，10 表示只允许在 4 核上执行**。

第二行命令查询到的结果表明写入 10 到 141 中断的 smp_affinity 文件成功，继续查看 /proc/interrupts 来确定是否真正生效。

操作记录如下：
```bash
[longyu@debian-10:20:30:02] 14 $ grep '141:' /proc/interrupts 
 141:     520162          0          0     596832       1465          0          0          0  IR-PCI-MSI 333824-edge      iwlwifi: default queue
[longyu@debian-10:20:30:28] 14 $ grep '141:' /proc/interrupts 
 141:     520162          0          0     596832       1639          0          0          0  IR-PCI-MSI 333824-edge      iwlwifi: default queue
[longyu@debian-10:20:30:31] 14 $ grep '141:' /proc/interrupts 
 141:     520162          0          0     596832       1805          0          0          0  IR-PCI-MSI 333824-edge      iwlwifi: default queue
```
可以看到 0 核与 3 核上的中断计数不再增加，4 核上的中断计数在增加表明**设定生效**。

## 默认 irq_mask 下的中断执行情况
上面的示例中选择 iwlwifi 的中断是有意为之的，在修改其中断亲和性前，查看 smp_affinity 确认使用的是默认的 irq_mask，值为全 F，表示中断服务程序可以在每一个核上运行，理想情况是**每个核上都有统计数据且负载均衡**，但是实际执行情况却是只在 0 核与 3 核上运行。

中断程序本身执行的代码少的可怜，只有当中断频繁到来的时候其影响才能表现出来，但是中断服务程序中会触发 soft irq，soft irq 做了很多工作且没有 irq_smp 来设定，网上搜索有说它会在被触发的核上执行，照这样来说那 **soft irq 也会随着 irq_smp 的改变而联动改变，但实际测试发现并没有这种效果**。

## soft irq 服务程序执行的 cpu
前言中我有描述过，在定位 dpdk 程序绑定到 0 核与 1 核上性能明显下降问题时，通过设定 smp_irq，性能有所提高，但是还是比使用后面的核低一些，**perf 查看发现 0 核上有较多的 softirq 负载**，这些 softirq 将会与测试程序一起共享 0 核，也会造成 dpdk 程序性能下降。

**那么 softirq 在哪个 cpu 上执行呢，它有与 irq smp_affinity 类似的设定接口吗？**

网上搜索了一下获取到了下面的信息：

	softirq 选择执行 cpu 的原则是在哪个 cpu 触发就在哪个 cpu 上执行

softirq 会在中断服务程序中触发，而 **smp_affinity** 掩码决定了中断服务程序的执行的 cpu 核，如果上面的描述成立，那么**只要修改了某个中断的 smp_affinity，此中断触发的 softirq 的执行 cpu 也应该随之变化**，而**实际情况是它没有变化**，这里就存在问题。

一段时候后我重新想了想这个问题，有下面两个方面的怀疑：

1. 网上的说法不可信

	我只简单看过 softirq 的代码，对具体的原理并不清楚，网上的说法存疑！

2. 我们的观测方法存在问题

	观测到 softirq 在某个核上执行，但是具体执行的 softirq 是哪个中断的 softirq 并没有深究
	
softirq 的工作过程有时间了要研究研究！扩展了这个知识，或许这里的问题便有了答案！
	


