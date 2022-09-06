# dpdk-16.04 igb_uio 模块分析
igb_uio 是 dpdk 内部实现的将网卡映射到用户态的内核模块，它是 uio 模块的一个实例。

igb_uio 是一种 pci 驱动，将网卡绑定到 igb_uio 隔离了网卡的内核驱动，同时 igb_uio 完成网卡中断内核态初始化并将中断信号映射到用户态。

igb_uio 与 uio 模块密切相关，我将从 uio 模块着手分析 igb_uio 模块的工作原理。

## uio 模块分析
uio 是一种**字符设备驱动**，在此驱动中注册了单独的 **file_operations 函数表**，uio 设备可以看做是一种独立的设备类型。

**file_operations** 函数内容如下：

```c
static const struct file_operations uio_fops = {
	.owner		= THIS_MODULE,
	.open		= uio_open,
	.release	= uio_release,
	.read		= uio_read,
	.write		= uio_write,
	.mmap		= uio_mmap,
	.poll		= uio_poll,
	.fasync		= uio_fasync,
	.llseek		= noop_llseek,
};
```
该函树表在 **uio_major_init** 中初始化 **cdev** 结构体时使用，相关代码如下：

```c
    cdev->owner = THIS_MODULE;
	cdev->ops = &uio_fops;
	kobject_set_name(&cdev->kobj, "%s", name);
	
	result = cdev_add(cdev, uio_dev, UIO_MAX_DEVICES);
```
我们对 /dev/uioxx 文件的操作最终都会对应到**对 uio_fops 的不同方法的调用上**。

## uio_info 结构体及其实例化过程
**uio** 模块中的 **idev** 变量是一个指向 **struct uio_device** 的指针，**struct uio_device** 中又包含 一个指向 **struct uio_info** 的指针，**struct uio_info** 结构体内容如下：

```c
struct uio_info {
	struct uio_device	*uio_dev;
	const char		*name;
	const char		*version;
	struct uio_mem		mem[MAX_UIO_MAPS];
	struct uio_port		port[MAX_UIO_PORT_REGIONS];
	long			irq;
	unsigned long		irq_flags;
	void			*priv;
	irqreturn_t (*handler)(int irq, struct uio_info *dev_info);
	int (*mmap)(struct uio_info *info, struct vm_area_struct *vma);
	int (*open)(struct uio_info *info, struct inode *inode);
	int (*release)(struct uio_info *info, struct inode *inode);
	int (*irqcontrol)(struct uio_info *info, s32 irq_on);
};
```
每一个 uio 设备都会**实例化**一个 uio_info 结构体，**uio 驱动自身不会实例化 uio_info** 结构体，它只提供一个**框架**，可以在其它模块中调用 **uio_register_device** 来**实例化 uio_info 结构体**，在 dpdk 中，常见方式是在**驱动绑定 igb_uio** 的时候调用 **uio_register_device** 进行实例化。

## igb_uio.c 中初始化当前设备 uio_info 结构过程
可以在 igb_uio.c 的 **probe** 函数 **igbuio_pci_probe** 中找到实例化的相关代码，摘录如下：

```c
410     /* remap IO memory */
411     err = igbuio_setup_bars(dev, &udev->info);
.....................................................
428     /* fill uio infos */
429     udev->info.name = "igb_uio";
430     udev->info.version = "0.1";
431     udev->info.handler = igbuio_pci_irqhandler;
432     udev->info.irqcontrol = igbuio_pci_irqcontrol;
433 #ifdef CONFIG_XEN_DOM0
434     /* check if the driver run on Xen Dom0 */
435     if (xen_initial_domain())
436         udev->info.mmap = igbuio_dom0_pci_mmap;
437 #endif
438     udev->info.priv = udev;
	
...........................................................

478     /* register uio driver */
479     err = uio_register_device(&dev->dev, &udev->info);
```
411 行调用 igbuio_setup_bars 映射 pci 设备 bar 中的内存区域，此函数代码如下：
```c
332 static int
333 igbuio_setup_bars(struct pci_dev *dev, struct uio_info *info)
334 {   
335     int i, iom, iop, ret;
336     unsigned long flags;
337     static const char *bar_names[PCI_STD_RESOURCE_END + 1]  = {
338         "BAR0",
339         "BAR1",
340         "BAR2",
341         "BAR3",
342         "BAR4",
343         "BAR5",
344     };
345     
346     iom = 0;
347     iop = 0;
348     
349     for (i = 0; i < ARRAY_SIZE(bar_names); i++) {
350         if (pci_resource_len(dev, i) != 0 &&
351                 pci_resource_start(dev, i) != 0) {
352             flags = pci_resource_flags(dev, i);
353             if (flags & IORESOURCE_MEM) {
354                 ret = igbuio_pci_setup_iomem(dev, info, iom,
355                                  i, bar_names[i]);
356                 if (ret != 0)
357                     return ret;
358                 iom++;
359             } else if (flags & IORESOURCE_IO) {
360                 ret = igbuio_pci_setup_ioport(dev, info, iop,
361                                   i, bar_names[i]);
362                 if (ret != 0)
363                     return ret;
364                 iop++;
365             }
366         }
367     }
368     
369     return (iom != 0) ? ret : -ENOENT;
370 }
```

它将 pci 设备每个 bar 的内存空间映射到 uio_info 结构中，可以分为两个类别：

1. IORESOURCE_MEM
2. IORESOURCE_IO

每个 bar 的 IORESOURCE_MEM 内存信息填充 uio_info 中的 mem 字段，相关代码如下：

```c
289     info->mem[n].name = name;
290     info->mem[n].addr = addr;
291     info->mem[n].internal_addr = internal_addr;
292     info->mem[n].size = len;
293     info->mem[n].memtype = UIO_MEM_PHYS;
```
n 从 0 开始，代表每一块独立的内存区域。

每个 bar 的 IORESOURCE_IO 内存信息填充 uio_info 中的 port 字段，相关代码如下：
```c
312     info->port[n].name = name;
313     info->port[n].start = addr;
314     info->port[n].size = len;
315     info->port[n].porttype = UIO_PORT_X86;
```
n 从 0 开始累加，代表每一块有效的 io 内存区域，igb_uio 中映射的 pci bar 的内存区域并不会被直接使用，在程序执行 mmap 映射 /dev/uioX 设备内存时 info 结构中的 mem 与 port 字段的值被使用，通过这样的方式将网卡的 pci 物理地址映射为用户态空间的虚拟地址。

**研究 dpdk-16.04 内部代码却发现它映射网卡 pci resource 地址，并不通过这种方式，实际是通过访问每个 pci 设备在 /sys 目录树下生成的 resource 文件获取 pci 内存资源信息，然后依次 mmap 每个 pci 内存资源对应的 resourceX 文件，这里执行的 mmap 将 resource 文件中的物理地址映射为用户态程序中的虚拟地址！**

## uio_info 结构体中 mem 与 port io 字段在 igb_uio 中填充的信息存在的意义

阅读 uio 模块代码，发现每个 uio 设备示例化过程中，会调用 **uio_dev_add_attributes** 创建 **maps 与 portio sysfs 属性**，网卡绑定到 igb_uio 后，我们可以通过访问 sysfs 目录中当前 pci 设备 uio maps 与 uio portio 文件来获取到网卡的 pci bar 中的物理内存信息。

示例如下：

```bash
 [root] # pwd
/sys/bus/pci/drivers/igb_uio/0000:00:06.0
 [root] # cat ./uio/uio2/maps/map0/addr ./uio/uio2/maps/map0/name  ./uio/uio2/maps/map0/size
0xfebf3000
BAR1
0x1000
 [root] # cat ./uio/uio2/portio/port0/start ./uio/uio2/portio/port0/name  ./uio/uio2/portio/port0/size ./uio/uio2/portio/port0/porttype
0xc080
BAR0
0x20
port_x86

```

如上信息说明 00:06.0 pci 接口，其有效 IORESOURCE_MEM 位于 BAR1 中，物理地址是 0xfebf3000，长度是 0x1000，有效 IORESOURCE_IO 位于 BAR0 中，物理地址是 0xc080，长度为 0x20，类型为 port_x86。

获取 resource 文件信息如下：

```bssh
 [root] # cat ./resource
0x000000000000c080 0x000000000000c09f 0x0000000000040101
0x00000000febf3000 0x00000000febf3fff 0x0000000000040200
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x00000000feb80000 0x00000000febbffff 0x000000000004e200
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
```

resource 文件信息每一行表示一个 pci 资源空间，dpdk 中只使用了前 6 个资源空间。每一个资源空间的第一列为起始物理地址，第二列为终止物理地址，第三列为 flag 标志。

其内容与 uio 生成的 maps 文件及 portio 文件的输出信息是一致的！实际上我们也可用通过 mmap /dev/uioX 来完成 pci 设备内存资源映射到用户态的工作。



## 如何通过 mmap /dev/uiox 文件来映射网卡 pci 内存资源
上文提到过，mmap /dev/uiox 需要通过 uio 生成的 maps 文件完成，从内核文档中找到与 maps 文件相关的如下信息：

Each `mapX/` directory contains four read-only files that show attributes of the memory:

- `name`: A string identifier for this mapping. This is optional, the string can be empty. Drivers can set this to make it easier for userspace to find the correct mapping.
- `addr`: The address of memory that can be mapped.
- `size`: The size, in bytes, of the memory pointed to by addr.
- `offset`: The offset, in bytes, that has to be added to the pointer returned by `mmap()` to get to the actual device memory. This is important if the device’s memory is not page aligned. Remember that pointers returned by `mmap()` are always page aligned, so it is good style to always add this offset.

From userspace, the different mappings are distinguished by adjusting the `offset` parameter of the `mmap()` call. To map the memory of mapping N, you have to use N times the page size as your offset:

```
offset = N * getpagesize();
```

不同的 pci 内存区域通过 offset 来区分，这就保证了当存在两个 pci 资源内存大小一致情况时的正常处理。

## igb_uio 模块的初始化与解初始化函数
igb_uio 模块的初始化与解初始化函数调用语句如下：
```c
568 module_init(igbuio_pci_init_module);
569 module_exit(igbuio_pci_exit_module);
```
igb_uio 模块可以看做是一个 pci 驱动的实例，其流程与 pci 驱动初始化过程类似，它实例化了一个 id_table 为空的 pci 驱动，在绑定网卡到 igb_uio 前需要先写入网卡的 vendor id 与 device id 到 igb_uio 驱动的 new_id 文件，动态扩充 igb_uio 支持的 pci 设备型号，这与常见的 pci 驱动有所区别。

igb_uio pci 驱动实例及初始化代码如下：
```c
543 static struct pci_driver igbuio_pci_driver = {
544     .name = "igb_uio",
545     .id_table = NULL,
546     .probe = igbuio_pci_probe,
547     .remove = igbuio_pci_remove,
548 };
549 
550 static int __init
551 igbuio_pci_init_module(void)
552 {
553     int ret;
554 
555     ret = igbuio_config_intr_mode(intr_mode);
556     if (ret < 0)
557         return ret;
558 
559     return pci_register_driver(&igbuio_pci_driver);
560 }
561 
```
igbuio_config_intr_mode 配置模块使用的中断模型，intr_mode 是 igb_uio 模块定义的一个模块参数，在加载模块的时候提供，没有指定时，默认使用 MSIX 中断模型。

559 行注册了 igbuio pci 设备，与之对应在解初始化函数中移除注册的 pci 驱动，函数代码如下：

```c
562 static void __exit
563 igbuio_pci_exit_module(void)
564 {
565     pci_unregister_driver(&igbuio_pci_driver);
566 }
```
## 网卡绑定到 igb_uio 时 probe 的过程
当网卡绑定到 igb_uio 时会执行 probe 操作，代码如下：

```c
377 igbuio_pci_probe(struct pci_dev *dev, const struct pci_device_id *id)
378 {
379     struct rte_uio_pci_dev *udev;
380     struct msix_entry msix_entry;
381     int err;
382 
383     udev = kzalloc(sizeof(struct rte_uio_pci_dev), GFP_KERNEL);
384     if (!udev)
385         return -ENOMEM;
386 
387     /*
388      * enable device: ask low-level code to enable I/O and
389      * memory
390      */
391     err = pci_enable_device(dev);
392     if (err != 0) {
393         dev_err(&dev->dev, "Cannot enable PCI device\n");
394         goto fail_free;
395     }
396 
397     /*
398      * reserve device's PCI memory regions for use by this
399      * module
400      */
401     err = pci_request_regions(dev, "igb_uio");
402     if (err != 0) {
403         dev_err(&dev->dev, "Cannot request regions\n");
404         goto fail_disable;
405     }
406 
407     /* enable bus mastering on the device */
408     pci_set_master(dev);
410     /* remap IO memory */
411     err = igbuio_setup_bars(dev, &udev->info);
412     if (err != 0)
413         goto fail_release_iomem;
414 
415     /* set 64-bit DMA mask */
416     err = pci_set_dma_mask(dev,  DMA_BIT_MASK(64));
417     if (err != 0) {
418         dev_err(&dev->dev, "Cannot set DMA mask\n");
419         goto fail_release_iomem;
420     }
421 
422     err = pci_set_consistent_dma_mask(dev, DMA_BIT_MASK(64));
423     if (err != 0) {
424         dev_err(&dev->dev, "Cannot set consistent DMA mask\n");
425         goto fail_release_iomem;
426     }
427 
.................................................................
439     udev->pdev = dev;
440 
441     switch (igbuio_intr_mode_preferred) {
442     case RTE_INTR_MODE_MSIX:
443         /* Only 1 msi-x vector needed */
444         msix_entry.entry = 0;
445         if (pci_enable_msix(dev, &msix_entry, 1) == 0) {
446             dev_dbg(&dev->dev, "using MSI-X");
447             udev->info.irq = msix_entry.vector;
448             udev->mode = RTE_INTR_MODE_MSIX;
449             break;
450         }
451         /* fall back to INTX */
452     case RTE_INTR_MODE_LEGACY:
453         if (pci_intx_mask_supported(dev)) {
454             dev_dbg(&dev->dev, "using INTX");
455             udev->info.irq_flags = IRQF_SHARED;
456             udev->info.irq = dev->irq;
457             udev->mode = RTE_INTR_MODE_LEGACY;
458             break;
459         }
460         dev_notice(&dev->dev, "PCI INTX mask not supported\n");
461         /* fall back to no IRQ */
462     case RTE_INTR_MODE_NONE:
463         udev->mode = RTE_INTR_MODE_NONE;
464         udev->info.irq = 0;
465         break;
466 
467     default:
468         dev_err(&dev->dev, "invalid IRQ mode %u",
469             igbuio_intr_mode_preferred);
470         err = -EINVAL;
471         goto fail_release_iomem;
472     }
473 
474     err = sysfs_create_group(&dev->dev.kobj, &dev_attr_grp);
475     if (err != 0)
476         goto fail_release_iomem;
477 
..............................................................
480     if (err != 0)
481         goto fail_remove_group;
482 
483     pci_set_drvdata(dev, udev);
484 
485     dev_info(&dev->dev, "uio device registered with irq %lx\n",
486          udev->info.irq);
487 
488     return 0;
489 
490 fail_remove_group:
491     sysfs_remove_group(&dev->dev.kobj, &dev_attr_grp);
492 fail_release_iomem:
493     igbuio_pci_release_iomem(&udev->info);
494     if (udev->mode == RTE_INTR_MODE_MSIX)
495         pci_disable_msix(udev->pdev);
496     pci_release_regions(dev);
497 fail_disable:
498     pci_disable_device(dev);
499 fail_free:
500     kfree(udev);
501 
502     return err;
503 }
```
383 行创建了一个 rte_uio_pci_dev 结构体实例，387~408 行使能 pci 设备并保留设备的 pci 内存区域到 igb_uio 模块中并使能总线控制。

411 行调用 igbuio_setup_bars 映射 pci 设备的 6 个 bar，并将内存地址及长度保存到 rte_uio_pci_dev 结构体的 info 字段中，详细信息见上文。

415~426 行设置 dma mask 信息，跳过了 uio_info 结构体初始化过程，这部分代码在探讨 uio 的时候描述。

441~472 行判断 igb_uio 使用的中断模型，根据不同的中断模型申请使能并填充中断信息。474 行创建了 igb_uio 内部的 sysfs 属性，这之后 483 行调用 pci_set_drvdata 将 udev 设置为 pci 设备的私有数据。



## dpdk 与 uio 设备文件的交互过程

dpdk 通过访问 uio 设备文件来完成物理网卡内核态的中断交互过程，阻塞式读取、epoll uio 文件来监听是否有中断事件，当中断到来后，read、epoll 系统调用返回，用户态中断回调函数执行完成后清除相应的中断标志位。

绑定网卡到 igb_uio 时，实例化一个 uio 设备的过程中会申请 request_irq，并传入了中断回调函数 uio_interrupt，这是 uio 能够捕获到中断信号的关键！

## 标准 UIO 设备控制中断过程

对于标准的 uio 设备，通过**向设备文件中写入 1** 来**使能**中断，与之类似**关闭中断**的过程是**向设备文件**中**写入 0**。

使用 uio 映射网卡到用户态时，网卡驱动会调用 **uio_intr_enable** 函数来使能 uio uio 中断。其代码摘录如下：

```c
static int
uio_intr_enable(struct rte_intr_handle *intr_handle)
{
	const int value = 1;

	if (write(intr_handle->fd, &value, sizeof(value)) < 0) {
		RTE_LOG(ERR, EAL,
			"Error enabling interrupts for fd %d (%s)\n",
			intr_handle->fd, strerror(errno));
		return -1;
	}
	return 0;
}
```
可以看到，这个函数通过写 1 到 uio 设备文件中来完成使能中断的过程。

## 写入 uio 设备文件有怎样的影响？
uio_write 是**写入 uio 设备文件时**内核中**最终调用到**的写入函数，其代码如下：

```c
static ssize_t uio_write(struct file *filep, const char __user *buf,
			size_t count, loff_t *ppos)
{	
	struct uio_listener *listener = filep->private_data;
	struct uio_device *idev = listener->dev;
	ssize_t retval;
	s32 irq_on;

	if (count != sizeof(s32))
		return -EINVAL;

	if (copy_from_user(&irq_on, buf, count))
		return -EFAULT;

	mutex_lock(&idev->info_lock);
	if (!idev->info) {
		retval = -EINVAL;
		goto out;
	}

	if (!idev->info || !idev->info->irq) {
		retval = -EIO;
		goto out;
	}

	if (!idev->info->irqcontrol) {
		retval = -ENOSYS;
		goto out;
	}

	retval = idev->info->irqcontrol(idev->info, irq_on);

out:
	mutex_unlock(&idev->info_lock);
	return retval ? retval : sizeof(s32);
}
```
可以看到它从**用户态**获取到 **irq_on** 这个变量的值，为 1 对应要使能中断，为 0 则表示关闭中断，在获取了这个参数后，它首先**占用互斥锁**，然后调用 info 结构体中实例化的 **irqcontrol** 子函数来完成工作。

## write 写入 uio 设备文件的完整过程
上文中我已经提到过使用 write 系统调用写入 uio 设备文件最终将会调用到 **info 结构体**中实例化的 **irqcontrol 子函数**来完成工作，igb_uio 就提供了这样一个函数。

也就是说在**绑定网卡到 igb_uio 时**，**写入**接口对应的 **uio 设备文件**时将会调用 igb_uio 中实例化的 **info->irqcontrol** 函数来**控制中断状态**。

这里提到的 **irqcontrol** 的实例化函数，在 igb_uio 中对应的就是 **igbuio_pci_irqcontrol** 函数。其代码如下：

```c
static int
igbuio_pci_irqcontrol(struct uio_info *info, s32 irq_state)
{
	struct rte_uio_pci_dev *udev = info->priv;
	struct pci_dev *pdev = udev->pdev;

	pci_cfg_access_lock(pdev);
	if (udev->mode == RTE_INTR_MODE_LEGACY)
		pci_intx(pdev, !!irq_state);

	else if (udev->mode == RTE_INTR_MODE_MSIX) {
		struct msi_desc *desc;

#if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 3, 0))
		list_for_each_entry(desc, &pdev->msi_list, list)
			igbuio_msix_mask_irq(desc, irq_state);
#else
		list_for_each_entry(desc, &pdev->dev.msi_list, list)
			igbuio_msix_mask_irq(desc, irq_state);
#endif
	}
	pci_cfg_access_unlock(pdev);

	return 0;
}
```

这里需要**访问 pci 配置空间**，根据不同的**中断类型**来控制中断状态。

## write 过程图示
![在这里插入图片描述](https://img-blog.csdnimg.cn/20210421152518118.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)


dpdk 程序在初始化网卡时会写入网卡接口对应的 uio 文件来使能中断，当中断使能后，一旦有中断到来，uio_interrupt 中断回调会被执行。

此回调函数代码如下：

```c

/**
 * uio_interrupt - hardware interrupt handler
 * @irq: IRQ number, can be UIO_IRQ_CYCLIC for cyclic timer
 * @dev_id: Pointer to the devices uio_device structure
 */
static irqreturn_t uio_interrupt(int irq, void *dev_id)
{
        struct uio_device *idev = (struct uio_device *)dev_id;
        irqreturn_t ret = idev->info->handler(irq, idev->info);

        if (ret == IRQ_HANDLED)
                uio_event_notify(idev->info);

        return ret;
}
```

它首先调用了 uio_info 中的 handler 函数，对 igb_uio 来说，此函数是 igbuio_pci_irqhandler，其源码如下：



```c
207 /**
208  * This is interrupt handler which will check if the interrupt is for the right device.
209  * If yes, disable it here and will be enable later.
210  */
211 static irqreturn_t
212 igbuio_pci_irqhandler(int irq, struct uio_info *info)
213 {
214     struct rte_uio_pci_dev *udev = info->priv;
215
216     /* Legacy mode need to mask in hardware */
217     if (udev->mode == RTE_INTR_MODE_LEGACY &&
218         !pci_check_and_mask_intx(udev->pdev))
219         return IRQ_NONE;
220
221     /* Message signal mode, no share IRQ and automasked */
222     return IRQ_HANDLED;
223 }
```

对于 Legacy 中断模式，需要设置硬件掩码值，我只关注返回 IRQ_HANDLED 的流程。当 handler 函数调用完成后，如果返回值是 IRQ_HANDLED，则调用 uio_event_notify 唤醒阻塞在 uio 设备等待队列中的进程，以通知用户态程序中断到达。

## dpdk 程序中监听中断事件的过程

dpdk 单独创建了一个中断线程负责监听并处理中断事件，其主要过程如下：

1. 创建 epoll_event
2. 遍历中断源列表，添加每一个需要监听的 uio 设备事件的 uio 文件描述符到 epoll_event 中
3. 调用 epoll_wait 监听事件，监听到事件后调用 eal_intr_process_interrupts 调用相关的中断回调函数