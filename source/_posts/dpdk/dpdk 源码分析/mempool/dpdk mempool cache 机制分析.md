# dpdk mempool cache 机制分析
## 前言
池是一种常见的设计技术，它将程序中常用的核心资源提前申请出来，放到一个【池子】里面，由程序自行管理资源的释放与申请。

dpdk 作为一种高性能数据转发套件，其中的关键资源是以 **mbuf** 结构描述的报文。程序收发包与中间的处理涉及到【频繁】的 mbuf 申请、释放操作，为了优化这一过程，dpdk 内部也使用了池技术来管理 mbuf。

dpdk 提供了类似内存池的结构，这一结构在 dpdk 内部称为 **mempool**，【专用】于 mbuf 的 mempool 又称为 **pktmbuf pool**。

dpdk 中 mbuf 使用的常见流程如下：
1. 程序初始化时创建一个 pktmbuf pool，按照特定的模式初始化创建的每个 mbuf 结构
2. 程序运行时从 pktmbuf pool 中申请 mbuf，释放 mbuf 时，mbuf 重新被添加到内存池中

## dpdk 内存池的 cache 功能
cache 是计算机体系中的一个非常重要的概念，它充当了 cpu 与主存之间的缓冲，平衡了 cpu 访问寄存器与访问主存之间的巨大差异，带了更好的性能。

cache 在计算机内存架构中的位置如下图所示：

![在这里插入图片描述](https://img-blog.csdnimg.cn/58157219eb4b4d5fb0fad60c60065f90.png)上图摘自 《CSAPP》。

上面的图形为正金字塔型，向上的方向上存储结构空间更小、访问速度更快、价格更昂贵，向下的方向存储结构空间更大、访问速度更慢、价格更便宜。

cache 的一般工作流程如下：

1. 当程序第一次访问某一字节存储空间时，这块空间不在 cache 中
2. cpu 以 cache line 为大小加载这一存储空间周围 64-byte（一个 cache line 的大小）长度的内容到 cache 中
3. 此后继续访问这 64-byte 字节中的内容就能够直接在 cache 中找到，不用去访问主存，进而带来更好的性能


cache 技术可以抽象为一种缓冲技术，它将少部分访问非常频繁的数据缓存起来，对这些数据的访问通过缓冲区完成，不用访问更底层的结构。

dpdk mempool 中就使用了缓冲技术，在 dpdk 内部称为 mempool cache，类比 cache 内存结构图，画了一个简单的 mempool cache 结构图如下：
![在这里插入图片描述](https://img-blog.csdnimg.cn/9d7922964ffa4b2ab886dee04a486c43.jpeg#pic_center)

与 cache 类似，mempool cache 中的元素更少，访问速度更快，在软件上的意义是执行更少的代码逻辑。

dpdk mempool 使用过程有些类似 cache 预取。

最开始的时候 mempool cache 中并**没有元素**，当你需要申请 n 个 mem 元素的时候不能在 cache 中找到（类似 cache miss），此时会访问外部的内存池，从内存池中直接出队 n + cache_size 大小个元素，加载到 cache 中，然后从 cache 中分配 n 个元素给上层。

这样当下一次分配的时候，当数目不超过 cache_size 时就可以直接从 cache 中分配，而不用再从外部内存池中分配。

下面我使用一个具体的实例，描述下 dpdk mempool cache 的工作原理。

## 1. mempool cache 结构
rte_mempool_cache 结构体描述一个 mempool cache，其结构如下图所示：

![在这里插入图片描述](https://img-blog.csdnimg.cn/2c81faa1e9c6448ba3c998d4b5d2bade.jpeg#pic_center)
size 表示 cache 的容量，flushthresh 表示将多余的元素 flush 到内存池的门限值，len 表示当前 cache 中的元素个数，objs 用于存储每个元素（以地址的形式储存）。

flushthresh 的计算公式如下：

```c
  #define CACHE_FLUSHTHRESH_MULTIPLIER 1.5
  #define CALC_CACHE_FLUSHTHRESH(c)   \
     ((typeof(c))((c) * CACHE_FLUSHTHRESH_MULTIPLIER))
```
其数量为 cache 大小的 **1.5 倍**！

objs 的大小为 **RTE_MEMPOOL_CACHE_MAX_SIZE * 3**，而在创建 mempool cache 时会限制最大为 **RTE_MEMPOOL_CACHE_MAX_SIZE**，**多出来的存储空间用于临时保存超过 cache size 数目的元素**。

## 2. 创建一个 pktmbuf mempool 并为每个逻辑核配置 mempool cache
dpdk 创建 pktmbuf pool 的示例代码如下：
```c
	#define MEMPOOL_CACHE_SIZE 6
	#define NB_MBUFS 1024
	
	/* create the mbuf pool */
	rte_pktmbuf_pool_create("mbuf_pool",
			NB_MBUFS, MEMPOOL_CACHE_SIZE, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
```
这里约定 cache size 为 6，NB_MBUFS 为 1024，同时约定使用了三个逻辑核,其它的参数不展开描述。

此函数调用后，dpdk 会在每个逻辑核上创建如下 mempool cache 结构：
![在这里插入图片描述](https://img-blog.csdnimg.cn/0ff3be5c27dc4be2bb9d621544a91080.png)
size 为 6 表明 cache 容量为 6 ，len 为 0 表明当前 cache 中没有元素。此时内存池的结构如下：

![在这里插入图片描述](https://img-blog.csdnimg.cn/228445d5b640419fb536242905b6d476.jpeg#pic_center)
如上图所示，pktmbuf pool 会为每个 lcore 按照传入的 cache_size 创建 mempool cache，此 cache 空间中保存内存池中单个元素的地址，初始化的时候 cache 的元素为空，内存池中的元素都在 **ring** 中入队。

## 3. 第一次从 mempool 中分配空间时 mempool cache 的变化
约定绑定在逻辑核 1 上的线程调用 ```rte_mempool_get_bulk```**申请 5 个 mbuf** ，实际从 mempool 中申请的 mbuf 数量为 cache_size + 5——11 个。

由于 **mempool cache** 与每个逻辑核绑定，首先要获取当前线程所在的逻辑核，然后获取此逻辑核上的 **mempool cache**。

然后判断要申请的 mem 的数量小于 cache 的缓存数目，则申请 **cache_size - cache_len + n** (6 + 5 - 0 = 11 ) 个数量的元素。

此后调用底层的出队函数，从内存池中拿出 11 个元素存储到 cache 中，如果失败则 bypass cache，直接从内存池中重新分配。

成功分配时后将 cache_len 递增 req（11） 个数目，然后从 cache 中拿走 n（5） 个元素，并调整 cache_len 为 6。

此时当前 lcore 上的 mempool_cache 内容如下：

![在这里插入图片描述](https://img-blog.csdnimg.cn/65b9606a27c6459c8b479b70c742d016.jpeg#pic_center)
cache 中保存了 memaddr0 ~memaddr5 共 6 个元素。

此时 mempool 中的元素如下：

![在这里插入图片描述](https://img-blog.csdnimg.cn/5218010a31024d30a8e43674a5a8e293.jpeg#pic_center)
mempool 中的前 11 个元素为空表示被分配出去，其中 6 个元素缓存在 cache 中，剩下的 5 个元素被上层程序占用，其它的元素仍旧在 mempool 中。

## 4. 第二次从 mempool 中分配 mubf 时 mempool cache 的变化
约定绑定在逻辑核 1 上的线程调用 ```rte_mempool_get_bulk```**继续申请 5 个 mbuf** ，此时 cache 中有 6 个元素，直接从 cache 中分配。

分配后逻辑核 1 上的 mempool_cache 状态如下：

![在这里插入图片描述](https://img-blog.csdnimg.cn/0e43273936cc471089bc71fd00305ee7.jpeg#pic_center)
此时 mempool 中的元素如下：

![在这里插入图片描述](https://img-blog.csdnimg.cn/0ebbb5200b8642f3ab9aed97d1a70688.jpeg#pic_center) 此时，上层占用了 10 个 mbuf，lcore1 mempool  cache 中存储了 1 个 mbuf，剩下的 1013 个 mbuf 都在 mempool 中。

## 5. 上层释放 mbuf 到 mempool 中
当上述 mbuf 使用完成后，上层释放 mbuf，约定上层在逻**辑核 1 上运行的线程中同时释放占用的 10 个 mbuf**。

释放过程的逻辑如下：

1. 获取线程所在逻辑核上的 mempool cache 结构
2. 判断传入的释放元素个数是否大于 RTE_MEMPOOL_CACHE_MAX_SIZE(512)，大于则直接放到 mempool 中，小于则放到 mempool cache 中
3. 判断 mempool cache 中存放的元素数目是否超过 flushthresh 值，超过后则将【超过 cache_size】 的部分重新放入 mempool 中并调整 cache_len 的值为 cache_size

当同时释放 10 个 mbuf 时，首先 mbuf 被放到逻辑核 1 上的 mempool cache 中，此时此 cache 中共有 10+1 个元素，然后判断到 11 大于 flushthresh(9)，则将多出来的 5 个元素放回 mempool 中。

执行此操作后 mempool cache 的状态如下：
![在这里插入图片描述](https://img-blog.csdnimg.cn/65b9606a27c6459c8b479b70c742d016.jpeg#pic_center)
mempool 的状态如下：

![在这里插入图片描述](https://img-blog.csdnimg.cn/229518eb437f429398e0e91925e19ad8.jpeg#pic_center)
## dpdk mempool cache 使用的一些问题
1. dpdk mempool 针对每个 lcore 配置 cache，dpdk lcore 机制可以参考 [dpdk-16.04 eal lcore 多线程机制分析](https://blog.csdn.net/Longyu_wlz/article/details/116398708)，对于单独使用 pthread_create 创建的线程，由于 lcore_id 为 -1，不能获取到 mempool cache，在这些线程中申请、释放元素到 mempool 中不会经过 cache
2. 每一个 lcore 上 mempool cache 的使用没有任何互斥保护，多个线程使用同一个 lcore 的情况下对 mempool cache 的访问会存在不一致性，这种场景下需要关闭 mempool cache 功能
3. 申请元素的线程所在的 lcore 要与释放元素的线程所在的 lcore **一致**，如果不一致就可能存在**泄露**部分元素的情况
	假设程序仅在 lcore 1 上申请 mbuf，而释放 mbuf 却在 lcore 2 上，这样就会泄露最多 mempool cache 初始化配置的容量大小个 mbuf
4. 在 cache 中分配、释放的概率越大性能越好
## 总结
这篇文章的背景是在实际的工作场景中遇到了一个 dpdk mbuf 泄露的问题，在这个问题中，将 mempool cache 的 size 改为 0 后问题得到解决，但是这只是个表面现象，不由得让人追问**难道 dpdk mempool cache 功能真的有严重的缺陷吗？**

于是带着这一疑问深入分析了下 mempool cache 的处理过程，结果发现确实存在一些限制因素，但是却没有找到所谓的严重缺陷，看来问题并没有这么简单，表面的现象说明不了太多问题。

写的过程中想到这个过程跟 cache 的一些原理有些相似，就类比着描述下，这个过程是在逐渐从具象走向抽象，当能完全理解抽象的模型后，就容易在不同的场景中迁移了。

## 参考链接
https://zhuanlan.zhihu.com/p/375537583