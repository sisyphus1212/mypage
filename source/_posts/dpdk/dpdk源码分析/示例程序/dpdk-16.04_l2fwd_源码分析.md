# dpdk-16.04 l2fwd 源码分析
l2fwd 是 dpdk 二层转发示例，它会将一个口收到的报文经过相邻口转发出去，在日常测试中经常用到。

下面我从源码入手，分析下 l2fwd 内部的工作原理。

## l2fwd 初始化 eal 并解析参数
```c
516 int
517 main(int argc, char **argv)
518 {
519     struct lcore_queue_conf *qconf;
520     struct rte_eth_dev_info dev_info;
521     int ret;
522     uint8_t nb_ports;
523     uint8_t nb_ports_available;
524     uint8_t portid, last_port;
525     unsigned lcore_id, rx_lcore_id;
526     unsigned nb_ports_in_mask = 0;
527 
528     /* init EAL */
529     ret = rte_eal_init(argc, argv);
530     if (ret < 0)
531         rte_exit(EXIT_FAILURE, "Invalid EAL arguments\n");
532     argc -= ret;
533     argv += ret;
534 
535     force_quit = false;
536     signal(SIGINT, signal_handler);
537     signal(SIGTERM, signal_handler);
538 
539     /* parse application arguments (after the EAL ones) */
540     ret = l2fwd_parse_args(argc, argv);
541     if (ret < 0)
542         rte_exit(EXIT_FAILURE, "Invalid L2FWD arguments\n");
```
第 529 行调用 rte_eal_init 初始化 eal 环境，由于 rte_eal_init 中会对 dpdk 内部的参数进行解析，l2fwd 需要调整 argc 与 argv 的位置以解析 l2fwd 自定义的参数。

第 535 将 force_quit 变量设置为 false，536 ~ 537 行注册了 SIGINT 与 SIGTERM 的信号处理函数 signal_handler，此函数代码如下：

```c
506 static void
507 signal_handler(int signum)
508 {
509     if (signum == SIGINT || signum == SIGTERM) {
510         printf("\n\nSignal %d received, preparing to exit...\n",
511                 signum);
512         force_quit = true;
513     }
514 }
```
signal_handler 函数向终端打印准备退出的信息，并且将 force_quit 设置为 true，当收发包线程检测到 force_quit 为 true 后主动退出，程序主动终止，退出前会释放占用的接口，使用如下代码：

```c
709     for (portid = 0; portid < nb_ports; portid++) {
710         if ((l2fwd_enabled_port_mask & (1 << portid)) == 0)
711             continue;
712         printf("Closing port %d...", portid);
713         rte_eth_dev_stop(portid);
714         rte_eth_dev_close(portid);
715         printf(" Done\n");
716     }
717     printf("Bye...\n");
```
在 for 循环中判断当前接口是否是 l2fwd 使能的接口，是则打印信息信息并 stop 与 close 接口，否则跳过接口。

第 540 行调用的 l2fwd_parse_args 解析 l2fwd 内部定义的参数，这些参数在 ```--```之后输入，与 dpdk 内部参数隔离开。

## l2fwd_parse_args 函数
l2fwd 支持三个参数，-p 参数使用十六进制掩码表示要使能的接口，每一位表示一个接口；-q 参数用于指定每个核上的队列数目；-T 参数用于指定时间周期，不太常用。

```c
380 /* Parse the argument given in the command line of the application */
381 static int
382 l2fwd_parse_args(int argc, char **argv)
383 {
384     int opt, ret;
385     char **argvopt;
386     int option_index;
387     char *prgname = argv[0];
388     static struct option lgopts[] = {
389         {NULL, 0, 0, 0}
390     };
391 
392     argvopt = argv;
393 
394     while ((opt = getopt_long(argc, argvopt, "p:q:T:",
395                   lgopts, &option_index)) != EOF) {
396 
397         switch (opt) {
398         /* portmask */
399         case 'p':
400             l2fwd_enabled_port_mask = l2fwd_parse_portmask(optarg);
401             if (l2fwd_enabled_port_mask == 0) {
402                 printf("invalid portmask\n");
403                 l2fwd_usage(prgname);
404                 return -1;
405             }
406             break;
407 
408         /* nqueue */
409         case 'q':
410             l2fwd_rx_queue_per_lcore = l2fwd_parse_nqueue(optarg);
411             if (l2fwd_rx_queue_per_lcore == 0) {
412                 printf("invalid queue number\n");
413                 l2fwd_usage(prgname);
414                 return -1;
415             }
416             break;
417 
418         /* timer period */
419         case 'T':
420             timer_period = l2fwd_parse_timer_period(optarg) * 1000 * TIMER_MILLISECOND;
421             if (timer_period < 0) {
422                 printf("invalid timer period\n");
423                 l2fwd_usage(prgname);
424                 return -1;
425             }   
426             break;
427             
428         /* long options */
429         case 0:
430             l2fwd_usage(prgname);
431             return -1;
432             
433         default:
434             l2fwd_usage(prgname);
435             return -1;
436         }   
437     }   
438 
439     if (optind >= 0)
440         argv[optind-1] = prgname;
441 
442     ret = optind-1;
443     optind = 0; /* reset getopt lib */
444     return ret;
```
第 532 与 533 行对 argc 与 argv 进行了调整，l2fwd 得以正常解析内部参数。l2fwd_parse_args 调用关系见下图：

![在这里插入图片描述](https://img-blog.csdnimg.cn/20210419211237930.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)
l2fwd 通过 getopt_long 依次解析每个参数，optarg 指向参数的值，通过调用 strtoul、strtol 来解析参数值并存储到相应的变量中。

参数解析完成后，l2fwd_enabled_port_mask 变量保存 l2fwd 程序要使能的接口，l2fwd_rx_queue_per_lcore 变量保存每一个逻辑核上的 rx 队列数目，timer_period 保存 drain 的时间。

## 创建 pktmbuf pool 并 reset l2fwd_dst_ports 结构体
```c
544     /* create the mbuf pool */
545     l2fwd_pktmbuf_pool = rte_pktmbuf_pool_create("mbuf_pool", NB_MBUF, 32,
546         0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
547     if (l2fwd_pktmbuf_pool == NULL)
548         rte_exit(EXIT_FAILURE, "Cannot init mbuf pool\n");
549 
550     nb_ports = rte_eth_dev_count();
551     if (nb_ports == 0)
552         rte_exit(EXIT_FAILURE, "No Ethernet ports - bye\n");
553 
554     if (nb_ports > RTE_MAX_ETHPORTS)
555         nb_ports = RTE_MAX_ETHPORTS;
556 
557     /* reset l2fwd_dst_ports */
558     for (portid = 0; portid < RTE_MAX_ETHPORTS; portid++)
559         l2fwd_dst_ports[portid] = 0;
560     last_port = 0;
```
第 545 行创建了 l2fwd 的 pktmbuf 内存池，pktmbuf 统一在 pktmbuf 内存池中分配回收，当创建失败后 l2fwd 打印失败信息并退出。

550~556 行获取可用的接口数量，当数量为 0 时打印失败信息后退出，当数量大于 config 中配置的最大接口数目时，将 nb_ports 重置为支持的最大接口数目。

557~560 行 reset 了 l2fwd_dst_ports，此数组用于保存相邻转发接口的关系，在收发包线程中被访问用于确定发包使用的端口号。

## 初始化转发端口关系数组
```c
562     /*
563      * Each logical core is assigned a dedicated TX queue on each port.
564      */
565     for (portid = 0; portid < nb_ports; portid++) {
566         /* skip ports that are not enabled */
567         if ((l2fwd_enabled_port_mask & (1 << portid)) == 0)
568             continue;
569 
570         if (nb_ports_in_mask % 2) {
571             l2fwd_dst_ports[portid] = last_port;
572             l2fwd_dst_ports[last_port] = portid;
573         }
574         else
575             last_port = portid;
576 
577         nb_ports_in_mask++;
578 
579         rte_eth_dev_info_get(portid, &dev_info);
580     }
581     if (nb_ports_in_mask % 2) {
582         printf("Notice: odd number of ports in portmask.\n");
583         l2fwd_dst_ports[last_port] = last_port;
584     }
```

565~584 完成 l2fwd_dst_ports 端口的关联表，**确定每个使能端口的发包端口**。当使能的端口数目为偶数时，**上一个口使用下一个口发包，下一个口使用上一个口发包**，当使能的端口数目为奇数时，**最后的单个口发包使用当前口**。

## 初始化每个 lcore 上绑定的收包端口关系数组
l2fwd 支持在单个 lcore 上绑定多个口进行收包，为此 l2fwd 定义了 lcore_queue_conf 结构体，此结构体的数量为系统支持的 lcore 的最大值。

相关代码如下：

```ｃ
101 static unsigned int l2fwd_rx_queue_per_lcore = 1;
102 
103 #define MAX_RX_QUEUE_PER_LCORE 16
104 #define MAX_TX_QUEUE_PER_PORT 16
105 struct lcore_queue_conf {
106     unsigned n_rx_port;
107     unsigned rx_port_list[MAX_RX_QUEUE_PER_LCORE];
108 } __rte_cache_aligned;
109 struct lcore_queue_conf lcore_queue_conf[RTE_MAX_LCORE];  
```

n_rx_port 代表一个 lcore_queue_conf 中绑定的收包端口数目，rx_port_list 中保存 lcore_queue_conf 中的每一个收包端口的 portid。

第 109 行定义 RTE_MAX_LCORE 的作用在于通过使用 lcore_id 这种每线程数据来隔离每个 lcore 的 queue_conf 配置。

lcore_queue_conf 初始化代码如下：

```c
586     rx_lcore_id = 0;
587     qconf = NULL;
588 
589     /* Initialize the port/queue configuration of each logical core */
590     for (portid = 0; portid < nb_ports; portid++) {
591         /* skip ports that are not enabled */
592         if ((l2fwd_enabled_port_mask & (1 << portid)) == 0)
593             continue;
594 
595         /* get the lcore_id for this port */
596         while (rte_lcore_is_enabled(rx_lcore_id) == 0 ||
597                lcore_queue_conf[rx_lcore_id].n_rx_port ==
598                l2fwd_rx_queue_per_lcore) {
599             rx_lcore_id++;
600             if (rx_lcore_id >= RTE_MAX_LCORE)
601                 rte_exit(EXIT_FAILURE, "Not enough cores\n");
602         }
603 
604         if (qconf != &lcore_queue_conf[rx_lcore_id])
605             /* Assigned a new logical core in the loop above. */
606             qconf = &lcore_queue_conf[rx_lcore_id];
607 
608         qconf->rx_port_list[qconf->n_rx_port] = portid;
609         qconf->n_rx_port++;
610         printf("Lcore %u: RX port %u\n", rx_lcore_id, (unsigned) portid);
611     }
612 
613     nb_ports_available = nb_ports;
```

596 ~ 603 行为当前 port 找到一个可用的 lcore_id，当 lcore_id 被使能，且此 lcore_id 对应的 queue_conf 中绑定的收包接口数目不等于 l2fwd_rx_queue_per_lcore（解析参数设定的每个核上的队列数目）时，此 lcore_id 可用。

不满足如上要求时，lcore_id 递增，当 lcore_id 的数目超过系统支持的最大 lcore 数目时，程序打印异常信息并退出。

604~606 行获取当前接口使用的 lcore 对应的 lcore_queue_conf 结构体地址，608~610 行将当前的 portid 赋值给 lcore_queue_conf 结构体中 rx_port_list 数组中的对应项目，然后对 n_rx_port 加 1，表示此 lcore_queue_conf 中绑定的端口数目又增加了一个。

l2fwd 默认在一个 lcore 上绑定一个接口，这样使能了几个接口就需要相应数目的 lcore，当 lcore 不足时就会因为无法分配 lcore 而退出。

## 初始化每一个使能的接口
```c
613     nb_ports_available = nb_ports;
614
615     /* Initialise each port */
616     for (portid = 0; portid < nb_ports; portid++) {
617         /* skip ports that are not enabled */
618         if ((l2fwd_enabled_port_mask & (1 << portid)) == 0) {
619             printf("Skipping disabled port %u\n", (unsigned) portid);
620             nb_ports_available--;
621             continue;
622         }
623         /* init port */
624         printf("Initializing port %u... ", (unsigned) portid);
625         fflush(stdout);
626         ret = rte_eth_dev_configure(portid, 1, 1, &port_conf);
627         if (ret < 0)
628             rte_exit(EXIT_FAILURE, "Cannot configure device: err=%d, port=%u\n",
629                   ret, (unsigned) portid);
630 
631         rte_eth_macaddr_get(portid,&l2fwd_ports_eth_addr[portid]);
632 
633         /* init one RX queue */
634         fflush(stdout);
635         ret = rte_eth_rx_queue_setup(portid, 0, nb_rxd,
636                          rte_eth_dev_socket_id(portid),
637                          NULL,
638                          l2fwd_pktmbuf_pool);
639         if (ret < 0)
640             rte_exit(EXIT_FAILURE, "rte_eth_rx_queue_setup:err=%d, port=%u\n",
641                   ret, (unsigned) portid);
642 
643         /* init one TX queue on each port */
644         fflush(stdout);
645         ret = rte_eth_tx_queue_setup(portid, 0, nb_txd,
646                 rte_eth_dev_socket_id(portid),
647                 NULL);
648         if (ret < 0)
649             rte_exit(EXIT_FAILURE, "rte_eth_tx_queue_setup:err=%d, port=%u\n",
650                 ret, (unsigned) portid);
651 
652         /* Initialize TX buffers */
653         tx_buffer[portid] = rte_zmalloc_socket("tx_buffer",
654                 RTE_ETH_TX_BUFFER_SIZE(MAX_PKT_BURST), 0,
655                 rte_eth_dev_socket_id(portid));
656         if (tx_buffer[portid] == NULL)                                    
660         rte_eth_tx_buffer_init(tx_buffer[portid], MAX_PKT_BURST);
661 
662         ret = rte_eth_tx_buffer_set_err_callback(tx_buffer[portid],
663                 rte_eth_tx_buffer_count_callback,
664                 &port_statistics[portid].dropped);
665         if (ret < 0)
666                 rte_exit(EXIT_FAILURE, "Cannot set error callback for "
667                         "tx buffer on port %u\n", (unsigned) portid);
668 
669         /* Start device */
670         ret = rte_eth_dev_start(portid);
671         if (ret < 0)
672             rte_exit(EXIT_FAILURE, "rte_eth_dev_start:err=%d, port=%u\n",
673                   ret, (unsigned) portid);
674 
675         printf("done: \n");
676 
677         rte_eth_promiscuous_enable(portid);
678 
679         printf("Port %u, MAC address: %02X:%02X:%02X:%02X:%02X:%02X\n\n",
680                 (unsigned) portid,
681                 l2fwd_ports_eth_addr[portid].addr_bytes[0],
682                 l2fwd_ports_eth_addr[portid].addr_bytes[1],
683                 l2fwd_ports_eth_addr[portid].addr_bytes[2],
684                 l2fwd_ports_eth_addr[portid].addr_bytes[3],
685                 l2fwd_ports_eth_addr[portid].addr_bytes[4],
686                 l2fwd_ports_eth_addr[portid].addr_bytes[5]);
687 
688         /* initialize port stats */
689         memset(&port_statistics, 0, sizeof(port_statistics));
690     }
```

第 613 行将 nb_port_available 变量的值设置为 nb_ports，其值代表 dpdk 可用的接口数目，检测到一个 dpdk 可用而 l2fwd 却没使能的接口，都将 nb_port_available 的值减一，当 for 循环遍历完成后，判断 nb_port_available 的值，如果变为 0，说明没有使能一个接口，打印报错信息并退出，相关代码如下：

```c
692     if (!nb_ports_available) {
693         rte_exit(EXIT_FAILURE,
694             "All available ports are disabled. Please set portmask.\n");
695     }   
```
当至少有一个接口使能时，623 行之后的逻辑会被执行。626 行调用 rte_eth_dev_configure 配置使用一个收发队列，且设置 port_conf。

631 行获取当前接口的 mac 地址并填充到 l2fwd_ports_eth_addr 数组中当前接口占用的表项中，这一 mac 地址在 l2fwd_simple_forward 函数修改报文的源 mac 地址时被使用，是典型的空间换时间的案例。

633 ～650 行初始化 rx queue 与 tx queue，设置每个 queue 上的描述符数目及使用的 pktmbuf 内存池，当设置失败时打印异常信息后退出。

652~668 行初始化当前 port 的 rte_eth_dev_tx_buffer 结构，此结构定义如下：

```ｃ
struct rte_eth_dev_tx_buffer {
	buffer_tx_error_fn error_callback;
	void *error_userdata;
	uint16_t size;           /**< Size of buffer for buffered tx */
	uint16_t length;         /**< Number of packets in the array */
	struct rte_mbuf *pkts[];
	/**< Pending packets to be sent on explicit flush or when full */
};
```

可以看到 pkts 数组没有设定大小，第 653 行调用 rte_zmalloc_socket 的时候，传递的大小为 RTE_ETH_TX_BUFFER_SIZE(MAX_PKT_BURST)。

RTE_ETH_TX_BUFFER_SIZE 的定义如下：

#define RTE_ETH_TX_BUFFER_SIZE(sz) \
	(sizeof(struct rte_eth_dev_tx_buffer) + (sz) * sizeof(struct rte_mbuf *))

可以发现它额外创建了 MAX_PKT_BURST 个指针，pkts 就指向这一额外内存区域，能够直接获取填充的 mbuf 地址。

第 660 行初始化 tx_buffer，注意此函数的第二个参数，这个参数指定了一个阀值，**当 tx_buffer 中的包数目低于此阀值时 rte_eth_tx_buffer 不会立刻发包出去，类似于缓冲功能**。 

同时需要说明的是 rte_eth_tx_buffer_init 会注册一个默认的回调函数 rte_eth_tx_buffer_drop_callback，此回调函数会**调用 rte_pktmbuf_free 将没有成功发送出去的包释放掉，缺少这一过程会导致 mbuf 泄露！**

662~668 行重新注册了一个回调函数，此回调函数在调用 rte_pktmbuf_free 释放未成功发送的报文后会将未成功发送的报文数目加到每个接口的 dropped 字段上。

669~689 行首先 start 接口，然后开启混淆模式，输出当前接口的 mac 地址并清空 l2fwd 的接口统计数据。

start 接口时会 up 接口，只有当接口处于 up 状态才能正常收发包，在收发包之前需要检查接口链路状态。

```c
697     check_all_ports_link_status(nb_ports, l2fwd_enabled_port_mask);
```
697 行就是检查接口 link 状态的逻辑，check_all_ports_link_status 会在 9s 内不断调用 rte_eth_link_get_nowait 获取每一个接口的 link 状态，当所有使能接口都 up、timeout 时，函数会设置 print_flag 变量为 1，打印接口状态信息后返回。

## 在每个 lcore 上运行 l2fwd_launch_one_lcore 函数
```c
699     ret = 0;
700     /* launch per-lcore init on every lcore */
701     rte_eal_mp_remote_launch(l2fwd_launch_one_lcore, NULL, CALL_MASTER);
702     RTE_LCORE_FOREACH_SLAVE(lcore_id) {
703         if (rte_eal_wait_lcore(lcore_id) < 0) {
704             ret = -1;
705             break;
706         }
707     }
```
701 行调用 rte_eal_mp_remote_launch 在每个使能的 lcore 上初始化将要运行的函数，设定每个 lcore 对应的 lcore_config 数据结构，并立即执行。

702~707 行依次获取每个 slave lcore 线程的状态，当 rte_eal_wait_lcore 函数返回值小于 0 时跳出循环。

## 收发包线程的执行过程
```c
311 static int
312 l2fwd_launch_one_lcore(__attribute__((unused)) void *dummy)                                                                                                              
313 {
314     l2fwd_main_loop();
315     return 0;
316 }
```
l2fwd_lanuch_one_lcore 会在每一个收发包线程上执行，它通过调用 l2fwd_main_loop 完成工作。

```ｃ
213 /* main processing loop */
214 static void
215 l2fwd_main_loop(void)
216 {
217     struct rte_mbuf *pkts_burst[MAX_PKT_BURST];
218     struct rte_mbuf *m;
219     int sent;
220     unsigned lcore_id;
221     uint64_t prev_tsc, diff_tsc, cur_tsc, timer_tsc;
222     unsigned i, j, portid, nb_rx;
223     struct lcore_queue_conf *qconf;
224     const uint64_t drain_tsc = (rte_get_tsc_hz() + US_PER_S - 1) / US_PER_S *
225             BURST_TX_DRAIN_US;
226     struct rte_eth_dev_tx_buffer *buffer;
227 
228     prev_tsc = 0;
229     timer_tsc = 0;
230 
231     lcore_id = rte_lcore_id();
232     qconf = &lcore_queue_conf[lcore_id];
233 
234     if (qconf->n_rx_port == 0) {
235         RTE_LOG(INFO, L2FWD, "lcore %u has nothing to do\n", lcore_id);
236         return;
237     }
238 
239     RTE_LOG(INFO, L2FWD, "entering main loop on lcore %u\n", lcore_id);
240 
241     for (i = 0; i < qconf->n_rx_port; i++) {
242 
243         portid = qconf->rx_port_list[i];
244         RTE_LOG(INFO, L2FWD, " -- lcoreid=%u portid=%u\n", lcore_id,
245             portid);
246 
247     }
```
231 行获取到当前线程的 lcore_id，232 行使用获取到的 lcore_id，获取到 lcore_queue_conf 中的表项。

234 行判断当前 lcore 绑定的收包端口数目，为 0 表示不收包，这一般是 master 线程。

241~247 行打印当前 lcore 绑定的每个端口号的 port_id。完成了这些操作后，进入到 while 循环中，注意循环终止条件为 force_quit 为 true，当 l2fwd 收到 SIGINT、SIGTERM 信号时就会将 force_quit 设置为 true，收发包线程检测到后就会退出循环。

```c
249     while (!force_quit) {
250 
251         cur_tsc = rte_rdtsc();
252 
253         /*
254          * TX burst queue drain
255          */
256         diff_tsc = cur_tsc - prev_tsc;
257         if (unlikely(diff_tsc > drain_tsc)) {
258 
259             for (i = 0; i < qconf->n_rx_port; i++) {
260 
261                 portid = l2fwd_dst_ports[qconf->rx_port_list[i]];
262                 buffer = tx_buffer[portid];
263 
264                 sent = rte_eth_tx_buffer_flush(portid, 0, buffer);
265                 if (sent)
266                     port_statistics[portid].tx += sent;
267 
268             }
269 
270             /* if timer is enabled */
271             if (timer_period > 0) {
272 
273                 /* advance the timer */
274                 timer_tsc += diff_tsc;
275 
276                 /* if timer has reached its timeout */
277                 if (unlikely(timer_tsc >= (uint64_t) timer_period)) {
278 
279                     /* do this only on master core */
280                     if (lcore_id == rte_get_master_lcore()) {
281                         print_stats();
282                         /* reset the timer */
283                         timer_tsc = 0;
284                     }
285                 }
286             }
287 
288             prev_tsc = cur_tsc;
289         }
291         /*
292          * Read packet from RX queues
293          */
294         for (i = 0; i < qconf->n_rx_port; i++) {
295 
296             portid = qconf->rx_port_list[i];
297             nb_rx = rte_eth_rx_burst((uint8_t) portid, 0,
298                          pkts_burst, MAX_PKT_BURST);
299 
300             port_statistics[portid].rx += nb_rx;
301 
302             for (j = 0; j < nb_rx; j++) {
303                 m = pkts_burst[j];
304                 rte_prefetch0(rte_pktmbuf_mtod(m, void *));
305                 l2fwd_simple_forward(m, portid);
306             }
307         }
308     }
309 }
```
收发包线程第一次执行时会先执行 294~307 行这个循环，此循环依次在当前 lcore 绑定的端口上收包，收到包后先增加 port_statistics 中的 rx 统计，然后对收到的每个报文调用 l2fwd_simple_forward。

```c
188 static void
189 l2fwd_simple_forward(struct rte_mbuf *m, unsigned portid)
190 {
191     struct ether_hdr *eth;
192     void *tmp;
193     unsigned dst_port;
194     int sent;
195     struct rte_eth_dev_tx_buffer *buffer;
196 
197     dst_port = l2fwd_dst_ports[portid];
198     eth = rte_pktmbuf_mtod(m, struct ether_hdr *);
199 
200     /* 02:00:00:00:00:xx */
201     tmp = &eth->d_addr.addr_bytes[0];
202     *((uint64_t *)tmp) = 0x000000000002 + ((uint64_t)dst_port << 40);
203 
204     /* src addr */
205     ether_addr_copy(&l2fwd_ports_eth_addr[dst_port], &eth->s_addr);
206 
207     buffer = tx_buffer[dst_port];
208     sent = rte_eth_tx_buffer(dst_port, 0, buffer, m);
209     if (sent)
210         port_statistics[dst_port].tx += sent;
211 }
```
l2fwd_simple_forward 函数中首先获取当前接口的转发接口，然后将转发接口的 mac 地址填充到报文的源 mac 地址处。

填充完成的报文通过调用 rte_eth_tx_buffer 投递到当前 lcore 的 tx_buffer 中，当 tx_buffer 中的报文数目小于门限值（32）的时候报文不会立刻发送出去。

为此 l2fwd 设定了一个 drain 延时，它的时间是 100 us，由于 l2fwd 使用 tsc 来计时，224 行将 100us 转化为了 tsc 周期数目。

251 行首先记录当前的 tsc 时间，减去上一次记录的时间就得到了延时，当延时大于 100us 的时候，遍历当前 lcore 上绑定的每一个端口，调用 rte_eth_tx_buffer_flush 来立刻发出 buffer 中的报文，然后增加发包统计。

270~287 行首先判断 timer_period 是否使能，当使能时，调整定时器的值（timer_tsc 的值），当 timer_tsc 的值大于等于 timer_period 表示一个周期到达，280~284 行判断当前线程是否是管理线程，是管理线程则调用 print_stats 输出统计，然后清空 timer_tsc 重新计数。

288 行更新上一次的 tsc 时间，这就完成了整个过程！