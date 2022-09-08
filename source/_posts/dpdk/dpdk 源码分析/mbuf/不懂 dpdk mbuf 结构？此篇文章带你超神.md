# 不懂 dpdk mbuf 结构？此篇文章带你超神
# dpdk 中 mbuf 的结构
![https://doc.dpdk.org/guides/prog_guide/mbuf_lib.html](https://img-blog.csdnimg.cn/2021061518410674.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)
图片摘自 [Mbuf Library](https://doc.dpdk.org/guides/prog_guide/mbuf_lib.html)。

dpdk 中的 mbuf 是网络报文的抽象结构，从上图中能够看出它可以分为四部分：

1. mbuf 结构体
2. headroom
3. dataroom
4. tailroom

这四部分中第一部分用于存储 mbuf 内部的数据结构，第二部分与第四部分的使用由用户控制，第三部分用于存储报文内容。

# mbuf 的日常操作
mbuf 的日常操作主要有如下几类：

1. 读取、写入 mbuf 结构中的不同字段
2. 从 pktmbuf pool 中 alloc  mbuf
3. 释放 mbuf 到 pktmbuf pool 中
4. 获取 mbuf 的 dataroom 的物理地址
5. 获取 mbuf 的 headroom 位置
6. 获取 mbuf 的 tailroom 的位置
7. 使用 mbuf 的 headroom 在 dataroom 前插入指定长度数据
8. 使用 mbuf 的 tailroom 在 dataroom 后插入指定长度数据
9. 使用已有的 mbuf 克隆一个新的 mbuf 

使用较为频繁的函数接口为申请 mbuf、释放 mbuf 等。

# dpdk 程序中 mbuf 的流动
mbuf 在创建 pktmbuf pool 的时候被放到以 ring 为代表的队列中，在开启网卡收包的时候会为每一个接收描述符申请一个 mbuf，并将 mbuf 中 dataroom 区域的总线地址写入到描述符的相关字段中，用**以 dma 处理时网卡填充报文到主机内存**。

**网卡收包时 mbuf 的流动：**

接口 up 的时候 dpdk 会为每个收包队列上的描述符申请 mbuf 并对 dataroom 的总线地址做 dma 映射，**由于描述符的基地址与长度写入了网卡寄存器，硬件能够操作描述符。**

硬件收到一个**正常的包**后会将包**拷贝到一个可用的描述符中配置的 dma 地址中**，同时**回写描述符中的不同字段**。

**软件收包**时，首先**判断是否有描述符上绑定的 dma 地址填充了报文**，对 **intel** 的网卡来说，一般通过检查描述符的 **dd** 位是否为 1 来判断。

当存在一个可用的描述符时，**收包函数会解析描述符内容**，同时获取到此描述符绑定的 mbuf，并用描述符中的不同字段填充 mbuf 中的一些字段，**保留解析描述符的结果**。

此后软件在将这个 mbuf 返回上层前，需要**重新分配一个新的 mbuf**，并将其 dataroom **起始地址的总线地址**填充到**描述符**中，这里的逻辑类似"狸猫换太子"，不过对象换成了空的 mbuf 与已经填充了报文的 mbuf。

当 mbuf 申请失败时，没有新的 mbuf 补充，收包会终止，dpdk 内部有一个 mbuf 申请失败的字段，此字段会加 1，当接口**不收包**时可以观测此字段确认是否由于 **mbuf 泄露**导致申请 mbuf 失败进而导致接口不收包。

**网卡发包时 mbuf 的流动:**

网卡发包时，上层将待发送的 mbuf 的指针数组传递到发包函数中。在发包函数中为**每一个待发送的包分配一个空闲的发送描述符**，同样，mbuf 的 dataroom 起始地址的总线地址会填充到描述符中，此外 mbuf 中的一些字段也会用于发包描述符填充。

这里存在一个问题：发包时我们填充 mbuf 的 dataroom 起始地址的总线地址到描述符中后，并**不会等待硬件发送完成**后释放 mbuf，那 **mbuf 是在哪里释放的**？**难道没有释放吗？**

在发包函数里面**即时判断报文是否发送完成**然后释放 mbuf 是可行的，但是这额外的等待带来的是**性能的损耗**。

intel 网卡的发包函数中进行了如下优化：

在获取到一个空闲的发包描述符时判断**此描述符上是否已经绑定了 mbuf**，如果已经绑定了表明这个包已经发送完成，就**释放 mbuf**。故而上一次绑定到描述符上的 mbuf，会在**下一次这个描述符状态空闲并被软件再次分配使用的时候释放**，这样既不影响功能，也提高了程序的性能。

一些驱动中同时使用 tx_free_thresh 门限，当空闲的描述符个数小于此门限值时，驱动会重新扫描描述符找到其它空闲的描述符。

**多个程序中 mbuf 的流动：**

基于 dpdk 开发的数通引擎可以主动申请 mbuf 并填充报文，然后调用发包函数发送出去。在收到包时可以将报文丢到 ring 中，**通过 ring 来将报文传送到指定位置**，实现与**诸如安全引擎等的联动**，这一过程是相互的，相互性意味着安全引擎也存在将处理过后的 mbuf 报文通过 ring 传送回数通引擎的情况。

这里的 ring 只是一种实现方案，dpdk 的无锁 ring 针对的是单个生产者与单个消费者的情况，在 dpdk 多进程方案设计时，为了避免对 ring 进行互斥保护，可以为每个 mbuf 传递方向都创建独立的 ring。

**kni 程序中 mbuf 的流动：**

kni 程序实现了一套高效的与内核之间传递报文的 fifo 机制，mbuf 的流动过程见下图：
![在这里插入图片描述](https://img-blog.csdnimg.cn/20210420203804299.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)这里需要注意两点问题：

1. 内核中使用的报文载体为 **sk_buff**，dpdk 中使用的是 **mbuf**，这两者需要转化，这里存在**报文拷贝**
2. mbuf 地址为**虚拟地址**，dpdk 程序中通过将虚拟地址转化为物理地址来将数据投递到内核，内核中再次将物理地址转化为内核的虚拟地址，然后进行访问

**物理地址对内核与用户态进程来说是唯一的**，但是内核与用户态进程都**不能直接访问物理地址**，需要再次进行**地址转化**，映射为相应的虚拟地址访问。

备注：**sk_buff 通过 netif_rx 函数将报文注入内核协议栈中。**

# mbuf 与性能
## 1. mbuf 的结构与性能
mbuf 作为 dpdk 中报文的载体，它的内容会被**频繁访问**，其**结构**对 dpdk 程序的**性能**有影响。

### 1.1 mbuf 结构与 cpu cache
如果你仔细观察过 mbuf 结构体的定义，你会发现有许多**非常规的方式**，无论是 **cache 行对齐**还是每个 **cache 的变量标号**，这都是 dpdk 针对 mbuf 的优化。

mbuf 结构是 cache 行对齐的，这样它能够被加载到连续的 cache 行中带来更好的性能。同时在 burst 模式中，也可以使用 cache 预取语句预先将即将处理的 mbuf 的内容使用指定 cache 行标号 load 到 cache 中。

### 1.2 mbuf 结构与向量指令
现代的处理器一般都支持**向量指令**，例如 intel 处理器支持的 **sse、avx2、avx512** 指令，**arm** 架构处理器支持的 **none** 指令，dpdk 作为各种性能优化方法的集大成者，也不可或缺的使用到了这些高级向量指令。

dpdk 收包逻辑中，核心过程是**解析收包描述符中的字段并填充到 mbuf 中**，基于 **burst** 的收包模式一般每次会收多个包（一般预期是 32 个)，在这种场景中解析描述符并填充到 mbuf 的操作存在**批量化的可能**。

引入向量指令，可以一次处理**多个**描述符，加之向量指令的执行时间与普通指令执行时间几乎一致（需要考证），这样就加速了收包处理过程。

使用向量收包函数带来的性能提高在小包场景是非常显著的。下图摘自 [DPDK Intel NIC Performance Report Release 20.11](http://fast.dpdk.org/doc/perf/DPDK_20_11_Intel_NIC_performance_report.pdf)
![在这里插入图片描述](https://img-blog.csdnimg.cn/95f6c97541fb41c5b59ad8461af0def7.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)
从上图中可以看出，在相同的测试环境下，使用 avx512 收发包函数相较 avx2 收发包函数带来了 **32.81% 的性能提升**，随着**包大小的提高**，**pps 显著下降**，使用 avx512 带来的性能提升效果也**逐渐下降**。

尽管对于大包来说，使用更高级的向量收发包指令并不能带来性能上太大的提升，但是实际使用过程中我发现它能够**降低 cpu 的利用率**，这在某些情景中也有重要的作用。

**mbuf 结构对向量收发包函数实现的影响：**

向量指令针对 128-bit、256-bit 等数据单元操作，将多个描述符合并到一起的过程是高效的，但是最终这些字段需要**拆分并依次填充到 mbuf 中的字段中**。

此时 mbuf 中字段的结构就显得非常重要了。

dpdk-16.04 中 mbuf 结构的 rearm_data 标号标识一个连续 6 字节长度的起始位置，相关定义如下：

```c
	/* next 6 bytes are initialised on RX descriptor rearm */                                                                                                         	
	MARKER8 rearm_data;
    uint16_t data_off;

    /**  
     * 16-bit Reference counter.                                                                                                                                             
     * It should only be accessed using the following functions:
     * rte_mbuf_refcnt_update(), rte_mbuf_refcnt_read(), and
     * rte_mbuf_refcnt_set(). The functionality of these functions (atomic,
     * or non-atomic) is controlled by the CONFIG_RTE_MBUF_REFCNT_ATOMIC
     * config option.
     */
    union {
        rte_atomic16_t refcnt_atomic; /**< Atomically accessed refcnt */
        uint16_t refcnt;              /**< Non-atomically accessed refcnt */
    };   
    uint8_t nb_segs;          /**< Number of segments. */
    uint8_t port;             /**< Input port. */

    uint64_t ol_flags;        /**< Offload features. */
```
dpdk-20.11 中 rearm_data 标识 8 个字节的起始位置，相关定义如下：

```c
496     /* next 8 bytes are initialised on RX descriptor rearm */
497     MARKER64 rearm_data;
498     uint16_t data_off;
499 
500     /**
501      * Reference counter. Its size should at least equal to the size
502      * of port field (16 bits), to support zero-copy broadcast.
503      * It should only be accessed using the following functions:
504      * rte_mbuf_refcnt_update(), rte_mbuf_refcnt_read(), and
505      * rte_mbuf_refcnt_set(). The functionality of these functions (atomic,
506      * or non-atomic) is controlled by the CONFIG_RTE_MBUF_REFCNT_ATOMIC
507      * config option.
508      */
509     RTE_STD_C11
510     union {
511         rte_atomic16_t refcnt_atomic; /**< Atomically accessed refcnt */
512         /** Non-atomically accessed refcnt */
513         uint16_t refcnt;
514     };
515     uint16_t nb_segs;         /**< Number of segments. */
516 
517     /** Input port (16 bits to support more than 256 virtual ports).
518      * The event eth Tx adapter uses this field to specify the output port.
519      */
520     uint16_t port;
521 
522     uint64_t ol_flags;        /**< Offload features. */
```
dpdk-20.11 mbuf 结构中 port 与 nb_segs 的大小变为了 **2 个字节**，带来的影响是 rearm_data 标识指向一个 **8-byte** 长度的起始位置，而 16.04 为 **6-byte**。

向量指令操作的单元基于 128-bit、256-bit，8-byte 为 64-bit 使用向量指令存储时逻辑简单，6-byte 为 48-bit，需要执行额外的拆分逻辑，这就是性能差异的一个点，同时这种拆分也提高了收发包函数的设计复杂度。

## 2. mbuf 的地址与性能
dpdk 程序一般会创建 pktmbuf_pool 内存池来存储 mbuf，在真实的业务场景中，收发包过程使用的 mbuf 的**地址离散时将会带来较差的性能**。

可以针对这个问题进行优化，使用某个线程**动态的控制 pktmbuf_pool 中的 mbuf 数量**来间接的**控制接口收发包分配的 mbuf 地址的分布**，使用更接近**连续的**分布来提高性能。

## 3. pktmbuf pool cache 与性能
dpdk 程序运行中需要频繁的申请与释放 mbuf，这些过程每次都直接操作 pktmbuf _pool 无疑会降低性能。

为此 dpdk 在 pktmbuf_pool 的基础上添加了**基于每个逻辑核的 mbuf cache 功能**，使能了 cache 并配置了大小的 pktmbuf_pool，在申请与释放的时候会**优先使用 cache**，避免直接操作 pktmbuf_pool 中的更底层的数据结构带来的性能损耗。

这里提到每个逻辑核的 mbuf cache 功能，将粒度**扩展到每个逻辑核**也是提高性能的手段，类似于**逻辑核本地数据**的方法。

不过在复杂的使用场景中，我就遇到过数通引擎中**多个线程绑定到同一个逻辑核中**，并且共**享了同一个 mempool** 的情况。

在这种场景中，mempool 中针对此逻辑核的 cache 被多个线程共享，当多个线程同时访问时就会出现**不一致**的情况，dpdk 内部并没有针对这个 cache 做**互斥处理**，常常遇到的情况是数通引擎莫名其妙段错误，**查看位置发现与 mbuf 内容相关，但是看逻辑却解释不了 mbuf 的变化**。

对于这种场景，可以针对性创建 cache_size 为 0 的 pktmbuf_pool 解决之。

# mbuf 与地址转换
dpdk-19.11 中有如下代码：

```c
    m->buf_iova = rte_mempool_virt2iova(m) + mbuf_size;  
```
**rte_mempool_virt2iova** 函数用于将 mbuf 的地址转化为物理地址，将物理地址加上 **mbuf_size** 执行 **mbuf** 中 **headroom** 起始位置的物理地址，可以从本文开篇出的那张图上看出来。

感兴趣的读者可以阅读下 **rte_mempool_virt2iova** 函数的代码，看看 **dpdk** 如何实现将**虚拟地址转化为物理地址**。

# 使用 mbuf 中的 headroom 与 tailroom
基于 dpdk 开发的数通引擎在收到报文后需要对报文进行解析，这个解析过程一般是一次性的，此后报文继续流动，在其它模块、进程中存在使用预先解析内容的情况，这时如果重新解析报文势必造成重复处理。

那么如何消除重复处理的情况呢？

此时 mbuf 的 headroom 与 tailroom 就派上了用场。每个 mbuf 中 headroom 的大小与 tailroom 的大小在创建的时候就已经确定，数通引擎中可以将解析报文得到的会被其它模块继续使用的字段存储到 mbuf 的 headroom、tailroom 中，其它模块、进程在获取到 mbuf 后，通过增加相应的偏移就能够获取到已经解析过程字段值。

## headroom 大小的问题
曾经在适配某 nxp dpaa2 网卡时，遇到 **headroom 大小限制**的问题。驱动、硬件中限制了 headroom 的大小不能超过 512，一旦超过就会收包异常，收到的报文都为 0。

我们的 dpdk 中配置的 headroom 大小超过了 512，这个大小是根据数通引擎中解析报文字段的需求设置的，**不能裁剪**。

**那么问题来了：如何解决 headroom 大小的问题呢？只能裁剪数通引擎中的相关结构定义吗？**

经过与同事的交流与思考，最终想到了一种解决方案：

将 headroom 的位置移动到 tailroom 中，**减少 headroom 的大小，增加 tailroom 的大小**以同时满足网卡的硬件限制 headroom 不能超过 512 的问题及数通引擎需要使用超过 512 大小的空间存储解析 mbuf 得到的字段的问题。

修改后测试确认问题得到解决。

# 总结
本篇文章描述了 dpdk mbuf 结构的一些特点及其在 dpdk 程序中的部分流动过程，跳过了一些相对使用率较少的功能描述，本文的描述不代表 mbuf 提供的完整功能，这一点需要注意。