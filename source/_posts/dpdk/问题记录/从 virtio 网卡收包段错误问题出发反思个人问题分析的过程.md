# 从 virtio 网卡收包段错误问题出发反思个人问题分析的过程
## 问题描述
kvm arm 虚拟机中 dpdk 业务程序使用 virtio 网卡收包时触发段错误，断在如下位置：
```c
#0  0x00000000004f2f9c in virtio_recv_pkts_vec ()
.....................................................
#5  0x00000000004e14d4 in rte_eal_mp_remote_launch ()
#6  0x000000000044ac64 in main ()
```
问题必现！
## 分析过程
### 确认版本信息
cpu 架构：**arm**
dpdk 版本：**dpdk-16.11**
dpdk 网卡驱动：**virtio pmd 驱动**

### 确认环境信息
cpu 信息：
```c
processor       : 0
model name      : ARMv8 CPU
bogomips        : 3600.00
Features        : fp asimd evtstrm aes pmull sha1 sha2 crc32
flags           : fp asimd evtstrm aes pmull sha1 sha2 crc32
CPU implementer : 0x41
CPU architecture: 8
CPU variant     : 0x0
CPU part        : 0xd08
CPU revision    : 2
```
cpu 为 ARMv8 处理器。

virtio 网卡 lspci -nvv 信息：

```c
00:03.0 0200: 1af4:1000
        Subsystem: 1af4:0001
        Control: I/O+ Mem+ BusMaster+ SpecCycle- MemWINV- VGASnoop- ParErr- Stepping- SERR- FastB2B- DisINTx+
        Status: Cap+ 66MHz- UDF- FastB2B- ParErr- DEVSEL=fast >TAbort- <TAbort- <MAbort- >SERR- <PERR- INTx-
        Latency: 0
        Interrupt: pin A routed to IRQ 42
        Region 0: I/O ports at 6040 [size=32]
        Region 1: Memory at 10ae5000 (32-bit, non-prefetchable) [size=4K]
        Region 4: Memory at 8000a00000 (64-bit, prefetchable) [size=16K]
        Expansion ROM at 10a40000 [disabled] [size=256K]
        Capabilities: [98] MSI-X: Enable+ Count=3 Masked-
                Vector table: BAR=1 offset=00000000
                PBA: BAR=1 offset=00000800
        Capabilities: [84] Vendor Specific Information: VirtIO: <unknown>
                BAR=0 offset=00000000 size=00000000
        Capabilities: [70] Vendor Specific Information: VirtIO: Notify
                BAR=4 offset=00003000 size=00001000 multiplier=00000004
        Capabilities: [60] Vendor Specific Information: VirtIO: DeviceCfg
                BAR=4 offset=00002000 size=00001000
        Capabilities: [50] Vendor Specific Information: VirtIO: ISR
                BAR=4 offset=00001000 size=00001000
        Capabilities: [40] Vendor Specific Information: VirtIO: CommonCfg
                BAR=4 offset=00000000 size=00001000
        Kernel driver in use: igb_uio
```
从 lspci -nvv 的信息能够确定此网卡为 virtio modern 类型。
### 段错误相关信息
使用 gdb 运行程序，出现段错误后反汇编得到如下信息：

```bash
(gdb) disass
Dump of assembler code for function virtio_recv_pkts_vec:
...........................................................
   0x00000000004f2f90 <+336>:   sub     v7.8h, v7.8h, v0.8h
   0x00000000004f2f94 <+340>:   tbl     v1.16b, {v1.16b}, v5.16b
   0x00000000004f2f98 <+344>:   stur    q19, [x19,#-16]
=> 0x00000000004f2f9c <+348>:   str     q18, [x2,#32]
   0x00000000004f2fa0 <+352>:   sub     v1.8h, v1.8h, v0.8h
```
段错误出在 str 指令存储 q18 寄存器的值到 x2 + 32 指向的内存区域时，表明 x2 + 32 这个内存区域不可访问。

```virtio_recv_pkts_vec```这个符号在 librte_pmd_virtio.a 中，编译 -O3 -g 版本的 librte_pmd_virtio.a 并使用 objdump -S -d 反汇编，找到如下代码：
```c
__extension__ static __inline void __attribute__ ((__always_inline__))
vst1q_u64 (uint64_t *a, uint64x2_t b)
{
  __builtin_aarch64_st1v2di ((__builtin_aarch64_simd_di *) a,
 158:   3c9f0273        stur    q19, [x19,#-16]
 15c:   3d800852        str     q18, [x2,#32]
}
```
能够确定是在调用 ```vst1q_u64```函数的时候触发了段错误，阅读 ```virtio_recv_pkts_vec```函数的源码，发现有多处调用，**没有找到**具体是哪一处调用触发。

### dpdk 示例程序对照测试
既然问题【必现】且问题出现在【驱动侧】，那使用相同版本的 l2fwd 测试，应该也能够复现问题。如果 l2fwd 能够复现问题则编译一个 -O3 -g 版本进一步定位，这样就不用依赖产品的业务程序。

使用 l2fwd 测试发现收发正常，同时使用 perf 观测到 l2fwd 使用的是 ```virtio_recv_pkts```
收包函数。
### 代码侧分析
在 dpdk 程序调用 **rte_eth_tx_queue_setup** 配置 virtio 接口队列的时候，会调用如下代码判断是否能够开启 vec 收包函数：

```c
#if defined RTE_ARCH_X86
        if (rte_cpu_get_flag_enabled(RTE_CPUFLAG_SSE3))
                use_simple_rxtx = 1;
#elif defined RTE_ARCH_ARM64 || defined CONFIG_RTE_ARCH_ARM
        if (rte_cpu_get_flag_enabled(RTE_CPUFLAG_NEON))
                use_simple_rxtx = 1;
#endif
        /* Use simple rx/tx func if single segment and no offloads */
        if (use_simple_rxtx &&
            (tx_conf->txq_flags & VIRTIO_SIMPLE_FLAGS) == VIRTIO_SIMPLE_FLAGS &&
            !vtpci_with_feature(hw, VIRTIO_NET_F_MRG_RXBUF)) {
                PMD_INIT_LOG(INFO, "Using simple rx/tx path");
                dev->tx_pkt_burst = virtio_xmit_pkts_simple;
                dev->rx_pkt_burst = virtio_recv_pkts_vec;
                hw->use_simple_rxtx = use_simple_rxtx;
        }
```
根据上文使用 l2fwd 的对照实验，我怀疑 dpdk 业务程序**不应该使用 vec 向量收包函数**，arm 架构上的 vec 向量收包函数依赖 neon 指令，我需要确定 **neon** 指令是否支持。

于是我百度了一下，发现了如下链接：[怎么查看 cpu 是否有 neon 指令 ](https://ask.zol.com.cn/x/5582053.html)。链接里面指出通过查看 /proc/cpuinfo 文件的内容就能够确定，示例信息中 **Features 中有 neon 字符**表示支持。

按照这个描述我确定虚拟机 cpu **不支持 neon 指令**，此时 **use_simple_rxtx** 为 0，最终 **virtio_recv_pkts_vec** 的配置【不会生效】，而产品业务程序却段错误断在 **virtio_recv_pkts_vec** 函数中，表明它使用的的确是这个 vec 收包函数，这里就存在问题！

## 初步分析结论
根据上文的分析，我判断产品的 dpdk 业务程序根本不应该使用 vec 收包函数，于是得出如下怀疑点：
1. 版本信息错误
2. dpdk 程序编译问题

找产品同学确认了上面的信息，没有找到疑点，有种大跌眼镜的感觉！
## 进一步分析结论
既然分析的结论与现实情况严重不符合又需要解决问题，只能编译一个带 dpdk 调试信息的产品业务程序来定位。

首先修改 dpdk 配置文件，开启如下调试信息：
```c
232 CONFIG_RTE_LIBRTE_VIRTIO_DEBUG_INIT=y
235 CONFIG_RTE_LIBRTE_VIRTIO_DEBUG_DRIVER=y
```
然后使用 **-O3 -g** 编译相同版本代码的 dpdk 库并重新编译产品 dpdk 业务程序。使用新的程序调试发现确实使用了 ```virtio_recv_pkts_vec```收包函数。

程序启动的打印也证明如下代码确实执行了：

```c
#elif defined RTE_ARCH_ARM64 || defined CONFIG_RTE_ARCH_ARM
        if (rte_cpu_get_flag_enabled(RTE_CPUFLAG_NEON))
                use_simple_rxtx = 1;
#endif
        /* Use simple rx/tx func if single segment and no offloads */
        if (use_simple_rxtx &&
            (tx_conf->txq_flags & VIRTIO_SIMPLE_FLAGS) == VIRTIO_SIMPLE_FLAGS &&
            !vtpci_with_feature(hw, VIRTIO_NET_F_MRG_RXBUF)) {
                PMD_INIT_LOG(INFO, "Using simple rx/tx path");
                dev->tx_pkt_burst = virtio_xmit_pkts_simple;
                dev->rx_pkt_burst = virtio_recv_pkts_vec;
                hw->use_simple_rxtx = use_simple_rxtx;
        }
```
定位到这里已经推翻了我之前的分析结论，事实表明此款 Armv8 处理器支持 neon 指令。

进一步阅读代码，我发现之前的分析中存在如下两个问题：

1. cat /proc/cpuinfo 中查看到没有 **neon** 并不代表处理器不支持 neon 指令，dpdk 实际是访问 **/proc/self/auxv** 文件来确定处理器支持的指令特性的，**当前 armv8 cpu 支持 neon 指令集**
2. l2fwd 与 dpdk 业务程序使用不同的收包函数，变化点不在于 neon 指令是否支持，而是上层配置的 tx_conf 中的 txq_flags 标志不一致

## 真正的问题是什么？

继续调试发现断在如下位置：

```c
(gdb) bt
165         vst1q_u64((void *)&rx_pkts[1]->rx_descriptor_fields1,                                                                                                            
166             pkt_mb[1]);
................................
```
问题原因为 rx_pkts[1] 指向的 mbuf 地址为空，访问这个空地址触发了段错误。进一步追问这个 mbuf 地址是从哪里来？它实际是通过如下代码从 sw_ring 中加载的。
```c
141         mbp[0] = vld1q_u64((uint64_t *)(sw_ring + 0));
142         desc[0] = vld1q_u64((uint64_t *)(rused + 0));
143         vst1q_u64((uint64_t *)&rx_pkts[0], mbp[0]);
```
打印 sw_ring 中的多个 mbuf 地址发现都为 NULL，记录如下：

```c
(gdb) print vq->sw_ring[0]
$26 = (struct rte_mbuf *) 0x0
(gdb) print vq->sw_ring[1]
$27 = (struct rte_mbuf *) 0x0
(gdb) print vq->sw_ring[2]
$28 = (struct rte_mbuf *) 0x0
```

**进一步追问为什么 sw_ring 中的 mbuf 为 NULL？**

根据过去阅读 intel 网卡驱动的经验，这个 sw_ring 一般是在为每个收包队列申请描述符的阶段赋值的，此后收包函数在将描述符的包向上层返回时会申请新的 mbuf 并更新相关的 sw_ring。

继续阅读代码确认 sw_ring 在 **virtio_dev_rx_queue_setup** 函数的如下代码上被配置：

```c
        /* Enqueue allocated buffers */
		if (hw->use_simple_rxtx)
			error = virtqueue_enqueue_recv_refill_simple(vq, m);
		else
			error = virtqueue_enqueue_recv_refill(vq, m);
```
这时候分析得出如下结论：
1. **virtqueue_enqueue_recv_refill_simple** 函数负责填充 mbuf 地址到 sw_ring 上
2. 确定 **hw->use_simple_rxtx** 在 **virtio_dev_tx_queue_setup** 中被重新赋值为 1
3. 确定 l2fwd 与产品 dpdk 业务程序中均先执行 **rx_queue_setup** 再执行 **tx_queue_setup** 

第三点与第二点因素导致 **rx_queue_setup** 中【不能判断】到 hw->use_simple_rxtx 为 1，则**未填充 sw_ring**，收包函数访问 sw_ring 中为 NULL 的 mbuf 时就会出现段错误。

这意味着这版的 virtio 驱动，需要先 tx_queue_setup 再 rx_queue_setup 才不会出问题，这一依赖明显不合理！

## 问题解决方案
搜索 dpdk git log，找到如下 commit 信息：

```c
commit efc83a1e7fc319876835738871bf968e7ed5c935
Author: Olivier Matz <olivier.matz@6wind.com>
Date:   Thu Sep 7 14:13:43 2017 +0200

    net/virtio: fix queue setup consistency

    In rx/tx queue setup functions, some code is executed only if
    use_simple_rxtx == 1. The value of this variable can change depending on
    the offload flags or sse support. If Rx queue setup is called before Tx
    queue setup, it can result in an invalid configuration:

    - dev_configure is called: use_simple_rxtx is initialized to 0
    - rx queue setup is called: queues are initialized without simple path
      support
    - tx queue setup is called: use_simple_rxtx switch to 1, and simple
      Rx/Tx handlers are selected

    Fix this by postponing a part of Rx/Tx queue initialization in
    dev_start(), as it was the case in the initial implementation.

    Fixes: 48cec290a3d2 ("net/virtio: move queue configure code to proper place")
    Cc: stable@dpdk.org

    Signed-off-by: Olivier Matz <olivier.matz@6wind.com>
    Acked-by: Yuanhan Liu <yliu@fridaylinux.org>
```

参考上述修改打 patch 即可解决问题！

## 反思
这个问题的分析过程有些波折，事后反思下发现确实存在一些值得思考的问题，主要问题列举如下。

### 1. 未批判性看待网上搜索到的信息
在想到这个问题的时候，我使用 starpage 搜索了一下，找到了如下链接：
[How to check the existence of NEON on arm?](https://stackoverflow.com/questions/26701262/how-to-check-the-existence-of-neon-on-arm)
[2.7.2. Run-time NEON unit detection](https://developer.arm.com/documentation/den0018/a/Compiling-NEON-Instructions/Detecting-presence-of-a-NEON-unit/Run-time-NEON-unit-detection)
相关的描述信息如下：
```
As the /proc/cpuinfo output is text based, it is often preferred to look at the auxiliary vector 
/proc/self/auxv. This contains the kernel hwcap in a binary format. The /proc/self/auxv file can 
be easily searched for the AT_HWCAP record, to check for the HWCAP_NEON bit (4096).
```
我当时并没有直接搜索，而是看了下 dpdk 解析 cpuflag 的代码，发现它是通过解析 ```/proc/self/auxv```文件来确定 arm cpu 支持的特殊指令，而不是通过访问 /proc/cpuinfo。其实这个思路是正确的，代码是第一手的资料，网上搜索的信息已经是好多手的资料了，其可信度已经大打折扣，对于这些信息应该批判性看待，不应该盲目的相信。

### 2. 当事实与分析不一致的时候，优先质疑了事实而不是分析过程
现阶段我解决问题的一般过程是这样的：
1. 在在线笔记中创建一个新的问题定位页面
2. 写下问题描述、环境信息、然后开始边收集信息边记录边分析问题
3. 分析不下去的时候，增加一个提问标题，写下当前的疑点
4. 寻找确定当前疑点的数据、证据
5. 重新审视问题与提出的疑点，循环这一过程，直至解决问题

随着上面这一过程的推广，我的问题解决能力得到了很大的提高，逐渐**从具体的问题走向寻找自己对问题的认知存在的问题**，往往当我将问题描述清楚，将一些提问项目明确结论时问题同时也得到了解决，这让我对自己的分析过程充满了信心，当事实与分析不一致时就容易出现否定事实的情况。

然而事实胜于雄辩，在工作上还是尽可能做的更客观一些，缺乏了客观就很容易被打脸。

### 3. 对比实验中忽略了关键的变化量，导致得出错误的结论
在这个问题中使用 l2fwd 做对比实验却没有找到真正的变化量。对于 l2fwd 与 dpdk 业务程序而言，**处理器是否支持 neon 的检测是使用同一套 dpdk 代码做的，变化点不在这里**，变化点实际在**两个程序的接口配置**中，忽略了这个变量，却误将 cpu 是否支持 neon 指令作为变量，进而得出了错误的结论。

这块还需要继续改进！

