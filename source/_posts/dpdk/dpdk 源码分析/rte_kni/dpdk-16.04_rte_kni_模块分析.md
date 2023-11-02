# dpdk-16.04 rte_kni 模块分析
## 前言
rte_kni 模块充当了用户态驱动与内核协议栈之间的桥梁，让 dpdk 程序能够上送流量到内核协议栈，同时也支持使用 ethtool、ifconfig 等重要的网络管理命令来控制接口状态。

**rte_kni 模块可以看作是一个虚拟的网卡驱动，符合网卡驱动的常见特征，其收发包过程却与网卡驱动有很大的差别，接口控制过程也不同于普通的网卡驱动，它涉及与 pmd 中频繁的交互工作，这是 rte_kni 功能的重点。**

**rte_kni 实现了一个虚拟网卡驱动，不存在网卡 probe 过程，故而不能直接初始化。同时 kni 虚拟网卡的初始化也依赖诸多用户态提供的参数，不符合正常虚拟网卡驱动流程。**

基于这些因素，rte_kni 还实现了一个字符驱动，**通过字符驱动的 open、ioctl、release 来控制虚拟网卡接口的创建、释放过程，而虚拟接口依赖的诸多参数也能通过 ioctl 来提供。**

同时为了支持 ethtool 命令获取数据，rte_kni 也模拟了网卡驱动初始化的过程并注册 ethtool_ops 结构体，这一部分的代码在高版本已经被移除。基于这点，本文集中叙述 rte_kni 虚拟网卡初始化与收发包的过程及与 pmd 交互的原理，ethtool 相关代码不在本文的探讨范围内。

## rte_kni 模块的目录结构
rte_kni 模块目录结构如下：

```bash
Makefile  compat.h  ethtool  kni_dev.h  kni_ethtool.c  kni_fifo.h  kni_misc.c  kni_net.c  kni_vhost.c
```

1. Makefile 文件为 rte_kni 编译脚本

2. compat.h 文件用于适配不同版本内核的一些接口
3. ethtool 目录中存放适配 igb、ixgbe 网卡 ethtool 功能的代码

4. kni_dev.h 中定义 kni device 等重要结构体

5. kni_ethtool.c 中定义 kni_ethtool_ops 结构体，此结构体中的方法封装了对 lad_dev->ethtool_ops 中方法的调用
6. kni_fifo.h 中定义共享队列的初始化、count、get、put 接口
7. kni_misc.c 中实现 kni 字符设备，以及操作这些字符设备文件的方法，如 open、ioctl 方法等
8. kni_net.c 中实现 kni 虚拟网络设备驱动
9. kni_vhost.c 是针对 vhost 的定制，不在本文探讨范围内

## kni 模块初始化过程

kni 模块初始化函数为 kni_init，其源码如下：

```c
155 static int __init
156 kni_init(void)
157 {
158     int rc;
159
160     KNI_PRINT("######## DPDK kni module loading ########\n");
161
162     if (kni_parse_kthread_mode() < 0) {
163         KNI_ERR("Invalid parameter for kthread_mode\n");
164         return -EINVAL;
165     }
166
167 #if LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 32)
168     rc = register_pernet_subsys(&kni_net_ops);
169 #else
170     rc = register_pernet_gen_subsys(&kni_net_id, &kni_net_ops);
171 #endif /* LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 32) */
172     if (rc)
173         return -EPERM;
174
175     rc = misc_register(&kni_misc);
176     if (rc != 0) {
177         KNI_ERR("Misc registration failed\n");
178         goto out;
179     }
180
181     /* Configure the lo mode according to the input parameter */
182     kni_net_config_lo_mode(lo_mode);
183
184     KNI_PRINT("######## DPDK kni module loaded  ########\n");
185
186     return 0;
187
188 out:
189 #if LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 32)
190     unregister_pernet_subsys(&kni_net_ops);
191 #else
192     register_pernet_gen_subsys(&kni_net_id, &kni_net_ops);
193 #endif /* LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 32) */
194     return rc;
195 }
```

此函数首先解析 kthread_mode 模块参数，根据参数设置 multiple_kthread_on、g_kni_net_rx 变量的值。

此后注册 kni 网络命名空间设备，kni_net_ops 中实例化的 kni_init_net 函数会在每个网络命名空间创建的时候被调用，创建一个 kni_net 结构，并初始化相应的数据结构，然后注册。

与此类似，kni_net_ops 中实例化的 kni_exit_net 函数在每个网络命令空间销毁时被调用，它会 free kni_net 结构。

175 行注册 kni misc 设备，成功后继续调用 kni_net_config_lo_mode 解析 lo_mode 模块参数，配置不同的 kni 收包函数，不太常用，不进行分析。

## kni misc 驱动的原理
kni misc 驱动实例化了一个 miscdevice 结构体， 此结构体中的 name 字段用于标识 kni misc 驱动，minor 字段指定设备 minor 号动态分配，fops 表示绑定在此设备文件上的文件操作方法。

1. kni_open 会在打开 /dev/kni 文件的时候被调用
2. kni_release 会在关闭 /dev/kni 文件的时候被调用
3. kni_ioctl 与 kni_compat_ioctl 在通过 ioctl 控制 /dev/kni 文件时被调用

实例化的数据结构定义如下：
```c
 73 static struct file_operations kni_fops = {
 74     .owner = THIS_MODULE,
 75     .open = kni_open,
 76     .release = kni_release,
 77     .unlocked_ioctl = (void *)kni_ioctl,
 78     .compat_ioctl = (void *)kni_compat_ioctl,
 79 };
 80 
 81 static struct miscdevice kni_misc = {
 82     .minor = MISC_DYNAMIC_MINOR,
 83     .name = KNI_DEVICE,
 84     .fops = &kni_fops,
 85 };
```
kni misc 设备使用时，用户态程序首先 open /dev/kni，然后执行 ioctl 并传递 RTE_KNI_IOCTL_CREATE 选项创建 kni 虚拟接口，然后正常运行，退出前继续调用 ioctl 并传递 RTE_KNI_IOCTL_RELEASE 释放 kni 虚拟接口，最后调用 close /dev/kni 来释放 kni 设备。

### kni_open
```c
231 static int
232 kni_open(struct inode *inode, struct file *file)
233 {
234     struct net *net = current->nsproxy->net_ns;
235     struct kni_net *knet = net_generic(net, kni_net_id);
236 
237     /* kni device can be opened by one user only per netns */
238     if (test_and_set_bit(KNI_DEV_IN_USE_BIT_NUM, &knet->device_in_use))
239         return -EBUSY;
240 
241     /* Create kernel thread for single mode */
242     if (multiple_kthread_on == 0) {
243         KNI_PRINT("Single kernel thread for all KNI devices\n");
244         /* Create kernel thread for RX */
245         knet->kni_kthread = kthread_run(kni_thread_single, (void *)knet,
246                         "kni_single");
247         if (IS_ERR(knet->kni_kthread)) {
248             KNI_ERR("Unable to create kernel threaed\n");
249             return PTR_ERR(knet->kni_kthread);
250         }
251     } else
252         KNI_PRINT("Multiple kernel thread mode enabled\n");
253 
254     file->private_data = get_net(net);
255     KNI_PRINT("/dev/kni opened\n");
256 
257     return 0;
258 }
```
238 行首先判断 kni_net 结构体中的 device_in_use 字段的值，确保每一个命名空间内只被一个用户占用。

241~252 行创建 kni 内核态线程，此线程用于 kni 收包，kthread_run 函数返回的线程描述符存储到 kni_net 结构体中的 kni_thread 字段中。

254 行将 kni net 结构体地址存储到当前进程 file 结构的 private_data 字段中，此字段在 kni_release 中被访问，kni_release 通过获取到 file 结构中预先存储的 kni net 结构来释放创建的内核线程与 kni 虚拟接口，释放完成后清除 kni_net 结构中的 device_in_use 字段表示此 kni 设备空闲。

kni_release 函数代码如下：
```c
254 static int
255 kni_release(struct inode *inode, struct file *file)
256 {
257     struct net *net = file->private_data;
258     struct kni_net *knet = net_generic(net, kni_net_id);
259     struct kni_dev *dev, *n;
260 
261     /* Stop kernel thread for single mode */                                                                                                                             
262     if (multiple_kthread_on == 0) {
263         /* Stop kernel thread */
264         kthread_stop(knet->kni_kthread);
265         knet->kni_kthread = NULL;
266     }
267 
268     down_write(&knet->kni_list_lock);
269     list_for_each_entry_safe(dev, n, &knet->kni_list_head, list) {
270         /* Stop kernel thread for multiple mode */
271         if (multiple_kthread_on && dev->pthread != NULL) {
272             kthread_stop(dev->pthread);
273             dev->pthread = NULL;
274         }
275 
276 #ifdef RTE_KNI_VHOST
277         kni_vhost_backend_release(dev);
278 #endif
279         kni_dev_remove(dev);
280         list_del(&dev->list);
281     }
282     up_write(&knet->kni_list_lock);
283 
284     /* Clear the bit of device in use */
285     clear_bit(KNI_DEV_IN_USE_BIT_NUM, &knet->device_in_use);
286 
287     put_net(net);
288     KNI_PRINT("/dev/kni closed\n");
289 
290     return 0;
291 }
```
### kni_ioctl 函数
kni_ioctl 函数控制 kni 虚拟网卡接口的创建与注销过程，其代码如下：
```c
628 static int
629 kni_ioctl(struct inode *inode,
630     unsigned int ioctl_num,
631     unsigned long ioctl_param)
632 {
633     int ret = -EINVAL;
634     struct net *net = current->nsproxy->net_ns;
635 
636     KNI_DBG("IOCTL num=0x%0x param=0x%0lx\n", ioctl_num, ioctl_param);
637 
638     /*
639      * Switch according to the ioctl called
640      */
641     switch (_IOC_NR(ioctl_num)) {
642     case _IOC_NR(RTE_KNI_IOCTL_TEST):
643         /* For test only, not used */
644         break;
645     case _IOC_NR(RTE_KNI_IOCTL_CREATE):
646         ret = kni_ioctl_create(net, ioctl_num, ioctl_param);
647         break;
648     case _IOC_NR(RTE_KNI_IOCTL_RELEASE):
649         ret = kni_ioctl_release(net, ioctl_num, ioctl_param);
650         break;
651     default:
652         KNI_DBG("IOCTL default\n");
653         break;
654     }
655 
656     return ret;
657 }
```
它根据 ioctl_num 来分发处理逻辑，RTE_KNI_IOCTL_TEST 仅用于测试，不执行任何逻辑，RTE_KNI_IOCTL_CREATE、RTE_KNI_IOCTL_RELEASE 分别用于创建、销毁 kni 虚拟网卡。

### kni_ioctl_create 函数
kni_ioctl_create 函数代码如下：
```c
389 static int
390 kni_ioctl_create(struct net *net,
391         unsigned int ioctl_num, unsigned long ioctl_param)
392 {
393     struct kni_net *knet = net_generic(net, kni_net_id);
394     int ret;
395     struct rte_kni_device_info dev_info;
396     struct pci_dev *pci = NULL;
397     struct pci_dev *found_pci = NULL;
398     struct net_device *net_dev = NULL;
399     struct net_device *lad_dev = NULL;
400     struct kni_dev *kni, *dev, *n;
401 
402     printk(KERN_INFO "KNI: Creating kni...\n");
403     /* Check the buffer size, to avoid warning */
404     if (_IOC_SIZE(ioctl_num) > sizeof(dev_info))
405         return -EINVAL;
406 
407     /* Copy kni info from user space */
408     ret = copy_from_user(&dev_info, (void *)ioctl_param, sizeof(dev_info));
409     if (ret) {
410         KNI_ERR("copy_from_user in kni_ioctl_create");
411         return -EIO;
412     }
413 
414     /**
415      * Check if the cpu core id is valid for binding,
416      * for multiple kernel thread mode.
417      */
418     if (multiple_kthread_on && dev_info.force_bind &&
419                 !cpu_online(dev_info.core_id)) {
420         KNI_ERR("cpu %u is not online\n", dev_info.core_id);
421         return -EINVAL;
422     }
423 
424     /* Check if it has been created */
425     down_read(&knet->kni_list_lock);
426     list_for_each_entry_safe(dev, n, &knet->kni_list_head, list) {
427         if (kni_check_param(dev, &dev_info) < 0) {
428             up_read(&knet->kni_list_lock);
429             return -EINVAL;
430         }
431     }
432     up_read(&knet->kni_list_lock);
433 
434     net_dev = alloc_netdev(sizeof(struct kni_dev), dev_info.name,
435 #ifdef NET_NAME_UNKNOWN
436                             NET_NAME_UNKNOWN,
437 #endif
438                             kni_net_init);
439     if (net_dev == NULL) {
440         KNI_ERR("error allocating device \"%s\"\n", dev_info.name);
441         return -EBUSY;
442     }
443 
444     dev_net_set(net_dev, net);
445 
446     kni = netdev_priv(net_dev);
447 
448     kni->net_dev = net_dev;
449     kni->group_id = dev_info.group_id;
450     kni->core_id = dev_info.core_id;
451     strncpy(kni->name, dev_info.name, RTE_KNI_NAMESIZE);
452 
453     /* Translate user space info into kernel space info */
454     kni->tx_q = phys_to_virt(dev_info.tx_phys);
455     kni->rx_q = phys_to_virt(dev_info.rx_phys);
456     kni->alloc_q = phys_to_virt(dev_info.alloc_phys);
457     kni->free_q = phys_to_virt(dev_info.free_phys);
459     kni->req_q = phys_to_virt(dev_info.req_phys);
460     kni->resp_q = phys_to_virt(dev_info.resp_phys);
461     kni->sync_va = dev_info.sync_va;
462     kni->sync_kva = phys_to_virt(dev_info.sync_phys);
463 
464     kni->mbuf_kva = phys_to_virt(dev_info.mbuf_phys);
465     kni->mbuf_va = dev_info.mbuf_va;
466 
467 #ifdef RTE_KNI_VHOST
468     kni->vhost_queue = NULL;
469     kni->vq_status = BE_STOP;
470 #endif
471     kni->mbuf_size = dev_info.mbuf_size;
472 
.............................................................. 
497     pci = pci_get_device(dev_info.vendor_id, dev_info.device_id, NULL);
499     /* Support Ethtool */
500     while (pci) {
501         KNI_PRINT("pci_bus: %02x:%02x:%02x \n",
502                     pci->bus->number,
503                     PCI_SLOT(pci->devfn),
504                     PCI_FUNC(pci->devfn));
505 
506         if ((pci->bus->number == dev_info.bus) &&
507             (PCI_SLOT(pci->devfn) == dev_info.devid) &&
508             (PCI_FUNC(pci->devfn) == dev_info.function)) {
509             found_pci = pci;
510             switch (dev_info.device_id) {
511             #define RTE_PCI_DEV_ID_DECL_IGB(vend, dev) case (dev):
512             #include <rte_pci_dev_ids.h>
513                 ret = igb_kni_probe(found_pci, &lad_dev);
514                 break;
.................................................................
520             default:
521                 ret = -1;
522                 break;
523             }
524 
525             KNI_DBG("PCI found: pci=0x%p, lad_dev=0x%p\n",
526                             pci, lad_dev);
527             if (ret == 0) {
528                 kni->lad_dev = lad_dev;
529                 kni_set_ethtool_ops(kni->net_dev);
530             } else {
531                 KNI_ERR("Device not supported by ethtool");
532                 kni->lad_dev = NULL;
533             }
534 
535             kni->pci_dev = found_pci;
536             kni->device_id = dev_info.device_id;
537             break;
538         }
539         pci = pci_get_device(dev_info.vendor_id,
540                 dev_info.device_id, pci);
541     }                                                                                                                                                                    
542     if (pci)
543         pci_dev_put(pci);
544 
545     ret = register_netdev(net_dev);
546     if (ret) {
547         KNI_ERR("error %i registering device \"%s\"\n",
548                     ret, dev_info.name);
549         kni_dev_remove(kni);
550         return -ENODEV;
551     }
552 
553 #ifdef RTE_KNI_VHOST
554     kni_vhost_init(kni);
555 #endif
556 
557     /**
558      * Create a new kernel thread for multiple mode, set its core affinity,
559      * and finally wake it up.
560      */
561     if (multiple_kthread_on) {
562         kni->pthread = kthread_create(kni_thread_multiple,
563                           (void *)kni,
564                           "kni_%s", kni->name);
565         if (IS_ERR(kni->pthread)) {
566             kni_dev_remove(kni);
567             return -ECANCELED;
568         }
569         if (dev_info.force_bind)
570             kthread_bind(kni->pthread, kni->core_id);
571         wake_up_process(kni->pthread);
572     }
573 
574     down_write(&knet->kni_list_lock);
575     list_add(&kni->list, &knet->kni_list_head);
576     up_write(&knet->kni_list_lock);
577 
578     return 0;
579 }
```
kni_ioctl_create 主要逻辑如下：

1. 从用户态拷贝 rte_kni_device_info 结构，填充到 dev_info 中
2. 判断 multiple_thread 模式是否开启，开启时则当设定了 dev_info 的 force_bind 选项后检查 dev_info 中设定的 core_id 是否合法，不合法则立即返回
3. 获取 kni_net 结构中 kni_list_lock 信号量，遍历 kni_net 的 kni_list_head 链表，检查待创建的接口是否已经被创建过，是则释放信号量并返回
4. 释放信号量并调用 alloc_netdev 创建一个 kni_net  netdev 接口，dev_info 的 name 字段为 netdev 的名称，kni_net_init 用于初始化此 netdev 结构中 kni 的私有变量
5. 建立 kni netdev 结构与 net 结构的关联，填充 kni_dev 中的字段，填充 txq、rxq 等共享 fifo 地址时调用 phys_to_virt 将物理地址转化为内核的虚拟地址使用
6. 循环调用 pci_get_device 依次遍历 pci 设备，当 pci 号与 dev_info 中配置的 pci 号一致时，根据 device id 来选择 probe 函数
7. device id 与 rte_pci_dev_ids.h 中定义的 igb、ixgbe 网卡匹配时，调用 igb_kni_probe、ixgbe_kni_probe 接口完成类似网卡驱动 probe 的过程，正常 probe 会继续创建一个 netdev 结构，此结构被存储到 lad_dev 中返回，此 lad_dev 的值最终被保存到 kni_net 结构中的 lad_dev 字段中，probe 成功后，kni 会设定 kni_net 中 net_dev 的 ethtool_ops 字段，此字段封装了对 lad_dev->ethtool_ops 中方法的调用。网卡不支持 ethtool 的时候 lad_dev 为空
8. 当 pci 有效时，调用 pci_dev_put 释放 pci 
9. 调用 register_netdev 注册 kni net_device 结构，失败则调用 kni_dev_remove 移除虚拟接口
10. multiple_thread 模式开启后，创建回调函数为 kni_thread_multiple  的内核线程并在 dev_info 中的 force_bind 字段设定时，绑定线程到指定的核上
11. 获取 kni_net 结构中的 kni_list_lock 信号量，注册 kni 设备到 kni_list_head 链表中，最后释放信号量

kni 在遍历 pci 列表并 probe 驱动的时候，使用了一个技巧，它在 probe igb 网卡时使用的代码如下：

```c
511             #define RTE_PCI_DEV_ID_DECL_IGB(vend, dev) case (dev):
512             #include <rte_pci_dev_ids.h>
513                 ret = igb_kni_probe(found_pci, &lad_dev);
```
首先定义了一个 RTE_PCI_DEV_ID_DECL_IGB 宏，此宏使用 dev 参数，预处理后则为 case (0201): 这种格式，它正好是一个以设备 id 为条件的 case 选项，包含了 rte_pci_dev_ids.h 后，所有的支持的 igb 网卡都会生成相关的 case，而这些 case 的主体函数都是 igb_kni_probe，这就是这里的机关。

## rte_kni 虚拟网络接口的收包函数
rte_kni 创建的虚拟网络接口支持多个收包函数，下面我以 kni_net_rx_normal 这个普通的函数为例，探讨这里的过程。

```c
128 static void
129 kni_net_rx_normal(struct kni_dev *kni)
130 {
131     unsigned ret;
132     uint32_t len;
133     unsigned i, num_rx, num_fq;
134     struct rte_kni_mbuf *kva;
135     struct rte_kni_mbuf *va[MBUF_BURST_SZ];
136     void * data_kva;
137 
138     struct sk_buff *skb;
139     struct net_device *dev = kni->net_dev;
140 
141     /* Get the number of free entries in free_q */
142     num_fq = kni_fifo_free_count(kni->free_q);
143     if (num_fq == 0) {
144         /* No room on the free_q, bail out */
145         return;
146     }
147 
148     /* Calculate the number of entries to dequeue from rx_q */
149     num_rx = min(num_fq, (unsigned)MBUF_BURST_SZ);
150 
151     /* Burst dequeue from rx_q */
152     num_rx = kni_fifo_get(kni->rx_q, (void **)va, num_rx);
153     if (num_rx == 0)
154         return;
155 
156     /* Transfer received packets to netif */
157     for (i = 0; i < num_rx; i++) {
158         kva = (void *)va[i] - kni->mbuf_va + kni->mbuf_kva;
159         len = kva->data_len;
160         data_kva = kva->buf_addr + kva->data_off - kni->mbuf_va
161                 + kni->mbuf_kva;
162 
163         skb = dev_alloc_skb(len + 2);
164         if (!skb) {
165             KNI_ERR("Out of mem, dropping pkts\n");
166             /* Update statistics */
167             kni->stats.rx_dropped++;
168         }
169         else {
170             /* Align IP on 16B boundary */
171             skb_reserve(skb, 2);
172             memcpy(skb_put(skb, len), data_kva, len);
173             skb->dev = dev;
174             skb->protocol = eth_type_trans(skb, dev);
175             skb->ip_summed = CHECKSUM_UNNECESSARY;
176 
177             /* Call netif interface */
178             netif_rx_ni(skb);
179 
180             /* Update statistics */
181             kni->stats.rx_bytes += len;
182             kni->stats.rx_packets++;
183         }
184     }
185 
186     /* Burst enqueue mbufs into free_q */
187     ret = kni_fifo_put(kni->free_q, (void **)va, num_rx);
188     if (ret != num_rx)
189         /* Failing should not happen */
190         KNI_ERR("Fail to enqueue entries into free_q\n");
191 }

```
此函数的主要逻辑如下：

1. 判断 free_q 中是否有空间，无则直接返回，有则继续下一步
2. 确定能够从 rx_q 中出队列的数目，此数目是 free_q 中的空闲数目与 burst 大小的最小值
3. 调用 kni_fifo_get 从 rx_q 队列中获取 num_rx 个 mbuf 的地址，数量为 0 则返回
4. 对于每个出队列的 mbuf，创建 sk_buff 结构，复制 mbuf 中的报文到 sk_buff 中并填充相关的字段，通过 netif_rx_ni 投递到内核协议栈并增加 kni 内部统计
5. 将 mbuf 释放到 free_q 队列中

## rte_kni 虚拟网络接口的发包函数
```c
390 static int
391 kni_net_tx(struct sk_buff *skb, struct net_device *dev)
392 {
393     int len = 0;
394     unsigned ret;
395     struct kni_dev *kni = netdev_priv(dev);
396     struct rte_kni_mbuf *pkt_kva = NULL;
397     struct rte_kni_mbuf *pkt_va = NULL;
398 
399     dev->trans_start = jiffies; /* save the timestamp */
400 
401     /* Check if the length of skb is less than mbuf size */
402     if (skb->len > kni->mbuf_size)
403         goto drop;
404 
405     /**
406      * Check if it has at least one free entry in tx_q and
407      * one entry in alloc_q.
408      */
409     if (kni_fifo_free_count(kni->tx_q) == 0 ||
410             kni_fifo_count(kni->alloc_q) == 0) {
411         /**
412          * If no free entry in tx_q or no entry in alloc_q,
413          * drops skb and goes out.
414          */
415         goto drop;
416     }
417 
418     /* dequeue a mbuf from alloc_q */
419     ret = kni_fifo_get(kni->alloc_q, (void **)&pkt_va, 1);
420     if (likely(ret == 1)) {
421         void *data_kva;
422 
423         pkt_kva = (void *)pkt_va - kni->mbuf_va + kni->mbuf_kva;
424         data_kva = pkt_kva->buf_addr + pkt_kva->data_off - kni->mbuf_va
425                 + kni->mbuf_kva;
426 
427         len = skb->len;
428         memcpy(data_kva, skb->data, len);
429         if (unlikely(len < ETH_ZLEN)) {
430             memset(data_kva + len, 0, ETH_ZLEN - len);           
431             len = ETH_ZLEN;
432         }
433         pkt_kva->pkt_len = len;
434         pkt_kva->data_len = len;
435 
436         /* enqueue mbuf into tx_q */
437         ret = kni_fifo_put(kni->tx_q, (void **)&pkt_va, 1);
438         if (unlikely(ret != 1)) {
439             /* Failing should not happen */
440             KNI_ERR("Fail to enqueue mbuf into tx_q\n");
441             goto drop;
442         }
443     } else {
444         /* Failing should not happen */
445         KNI_ERR("Fail to dequeue mbuf from alloc_q\n");
446         goto drop;
447     }
448 
449     /* Free skb and update statistics */
450     dev_kfree_skb(skb);
451     kni->stats.tx_bytes += len;
452     kni->stats.tx_packets++;
453 
454     return NETDEV_TX_OK;
455 
456 drop:
457     /* Free skb and update statistics */
458     dev_kfree_skb(skb);
459     kni->stats.tx_dropped++;
460 
461     return NETDEV_TX_OK;
462 }
```
当内核协议栈要通过 kni 接口发包时，会调用到 kni_net_tx 函数，此函数的主要逻辑如下：

1. 判断 alloc_q 与 tx_q 中是否有空闲项目，无空闲项目则丢弃 sk_buff 并增加统计
2. 从 alloc_q 中获取一个 mbuf 地址，获取失败则丢弃 sk_buff 并增加统计
3. 获取到 mbuf 地址后将 sk_buff 中的报文填充到 mbuf 中然后放到 tx_q 队列中
4. 释放 sk_buff 结构并增加统计

## rte_kni 虚拟接口收发包中 mbuf 的流动过程
下图形象的表示出了 kni 虚拟接口收发过程中 mbuf 的流动，摘自 dpdk 官网：
![在这里插入图片描述](https://img-blog.csdnimg.cn/20210422084914778.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)

可以参考 [dpdk-16.04 kni 示例程序分析](https://blog.csdn.net/Longyu_wlz/article/details/115918403?spm=1001.2014.3001.5501) 来学习。
## 释放 kni 虚拟接口的过程
释放 kni 虚拟接口时，用户态程序调用 ioctl 并传递 RTE_KNI_IOCTL_RELEASE 参数，内核态中会调用 kni_ioctl_release 函数，此函数代码如下：

```c
581 static int
582 kni_ioctl_release(struct net *net,
583         unsigned int ioctl_num, unsigned long ioctl_param)
584 {
585     struct kni_net *knet = net_generic(net, kni_net_id);
586     int ret = -EINVAL;
587     struct kni_dev *dev, *n;
588     struct rte_kni_device_info dev_info;
589 
590     if (_IOC_SIZE(ioctl_num) > sizeof(dev_info))
591             return -EINVAL;
592 
593     ret = copy_from_user(&dev_info, (void *)ioctl_param, sizeof(dev_info));
594     if (ret) {
595         KNI_ERR("copy_from_user in kni_ioctl_release");
596         return -EIO;
597     }
598 
599     /* Release the network device according to its name */
600     if (strlen(dev_info.name) == 0)
601         return ret;
602 
603     down_write(&knet->kni_list_lock);
604     list_for_each_entry_safe(dev, n, &knet->kni_list_head, list) {
605         if (strncmp(dev->name, dev_info.name, RTE_KNI_NAMESIZE) != 0)
606             continue;
607 
608         if (multiple_kthread_on && dev->pthread != NULL) {
609             kthread_stop(dev->pthread);
610             dev->pthread = NULL;
611         }
612 
613 #ifdef RTE_KNI_VHOST
614         kni_vhost_backend_release(dev);
615 #endif
616         kni_dev_remove(dev);
617         list_del(&dev->list);
618         ret = 0;
619         break;
620     }
621     up_write(&knet->kni_list_lock);
622     printk(KERN_INFO "KNI: %s release kni named %s\n",
623         (ret == 0 ? "Successfully" : "Unsuccessfully"), dev_info.name);
624         
625     return ret;
626 }
```
此函数的主要逻辑如下：

1. 从用户态复制参数到 dev_info 结构体中
2. 获取 kni_net 结构体的 kni_list_lock 信号量，遍历 kni_list_head 链表，使用 dev_info.name 来匹配，匹配成功后释放 kni 设备中创建的内核线程，调用 kni_dev_remove 执行网卡相关数据结构的释放过程
3. 将当前设备从 kni_net 链表中移除
4. 释放完成后，释放获取到的 kni_list_lock 信号量

kni_dev_remove 与 kni_ioctl_create 有相同之处，它首先匹配驱动，匹配到后则调用网卡的 xx_kni_remove 函数来释放 xx_kni_probe 函数中创建的相关数据结构，此后当 kni 设备中 net_dev 存在时，unregister net_dev 并释放此结构。

kni_dev_remove 代码如下：

```c
347 static int
348 kni_dev_remove(struct kni_dev *dev)
349 {
350     if (!dev)
351         return -ENODEV;
352 
353     switch (dev->device_id) {
354     #define RTE_PCI_DEV_ID_DECL_IGB(vend, dev) case (dev):
355     #include <rte_pci_dev_ids.h>
356         igb_kni_remove(dev->pci_dev);
357         break;
358     #define RTE_PCI_DEV_ID_DECL_IXGBE(vend, dev) case (dev):
359     #include <rte_pci_dev_ids.h>
360         ixgbe_kni_remove(dev->pci_dev);
361         break;
362     default:
363         break;
364     }
365 
366     if (dev->net_dev) {
367         unregister_netdev(dev->net_dev);
368         free_netdev(dev->net_dev);
369     }
370 
371     return 0;
372 }
```
在执行了上述过程后，程序通过 close /dev/kni 来释放 kni 设备文件，此过程在内核中通过调用 kni_release 函数来完成，其代码如下：

```c
254 static int
255 kni_release(struct inode *inode, struct file *file)
256 {
257     struct net *net = file->private_data;
258     struct kni_net *knet = net_generic(net, kni_net_id);
259     struct kni_dev *dev, *n;
260 
261     /* Stop kernel thread for single mode */
262     if (multiple_kthread_on == 0) {
263         /* Stop kernel thread */
264         kthread_stop(knet->kni_kthread);
265         knet->kni_kthread = NULL;
266     }
267 
268     down_write(&knet->kni_list_lock);
269     list_for_each_entry_safe(dev, n, &knet->kni_list_head, list) {
270         /* Stop kernel thread for multiple mode */
271         if (multiple_kthread_on && dev->pthread != NULL) {
272             kthread_stop(dev->pthread);
273             dev->pthread = NULL;
274         }
275 
276 #ifdef RTE_KNI_VHOST
277         kni_vhost_backend_release(dev);
278 #endif
279         kni_dev_remove(dev);
280         list_del(&dev->list);
281     }
282     up_write(&knet->kni_list_lock);
283 
284     /* Clear the bit of device in use */
285     clear_bit(KNI_DEV_IN_USE_BIT_NUM, &knet->device_in_use);
286 
287     put_net(net);
288     KNI_PRINT("/dev/kni closed\n");
289 
290     return 0;
291 }
```
其过程类似 kni_ioctl_release，却增加了对 kni_net 中创建的内核线程的释放过程，并将 kni_net 中的 device_in_use 置位，表明设备空闲，然后调用 put_net 递减 net 结构的引用计数，打印信息后退出。

## 为什么 dpdk 程序被强制杀死的时候 kni 接口被释放？
当 dpdk 程序被强制杀死时，内核会回收文件描述符，调用 kni_release 来释放 kni 虚拟网卡设备。

## rte_kni 模块的解初始化函数
rte_kni 模块的解初始化函数为 kni_exit，此函数中首先解除 kni misc 设备注册信息，然后解除注册的每网络命令空间的 kni_net_ops 操作。

其代码如下：

```c
197 static void __exit
198 kni_exit(void)                                                                                                                                                           
199 {
200     misc_deregister(&kni_misc);
201 #if LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 32)
202     unregister_pernet_subsys(&kni_net_ops);
203 #else
204     register_pernet_gen_subsys(&kni_net_id, &kni_net_ops);
205 #endif /* LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 32) */
206     KNI_PRINT("####### DPDK kni module unloaded  #######\n");
207 }
```