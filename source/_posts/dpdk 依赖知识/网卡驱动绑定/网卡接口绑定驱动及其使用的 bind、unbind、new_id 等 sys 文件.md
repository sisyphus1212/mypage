# 网卡接口绑定驱动及其使用的 bind、unbind、new_id 等 sys 文件

## 一个特定的虚拟机环境

在我的虚拟机中，有如下网络接口：

```bash
01:00.0 Ethernet controller: Red Hat, Inc Virtio network device (rev 01)
04:00.0 Ethernet controller: Intel Corporation 82574L Gigabit Network Connection
08:00.0 Ethernet controller: Intel Corporation 82574L Gigabit Network Connection
09:00.0 Ethernet controller: Intel Corporation 82574L Gigabit Network Connection
```

这里第一个网络接口为 virtio 网卡，后三个都是 e1000e 虚拟网卡 82574L。

在 dpdk 的使用过程中我们常常需要将网卡绑定到不同的驱动上，dpdk 提供了一个 ```dpdk_nic_bind.py``` 脚本来简化这一任务，这个脚本的具体用法不在本文的描述范围内，感兴趣的读者可以研究研究。

注意这里的 01:00.0、04:00.0、08:00.0、09:00.0 表示的是网络接口 pci 设备对应的 **pci** 号，**这些 pci 号唯一标识一个接口，在绑定驱动与解绑驱动时会使用到。**

## 与网卡接口绑定驱动相关的文件与操作

网卡接口绑定驱动主要与 **bind** 与 **new_id** 两个 sysfs 文件有关。在我的系统上，我搜索 /sys 下名为 bind 的文件，搜索到了不同驱动的 bind 文件，截取部分信息如下：

```
/sys/bus/pci/drivers/shpchp/bind
/sys/bus/pci/drivers/agpgart-sis/bind
/sys/bus/pci/drivers/e1000e/bind
```

这里我以 e1000e 驱动为例，查看每一个 /sys/bus/pci/dirvers 子目录中有哪些东东。

执行 ls 命令查看 /sys/bus/pci/drivers/e1000e 目录的内容，输出信息如下：

```
0000:04:00.0  0000:08:00.0  0000:09:00.0  bind  module  new_id  remove_id  uevent  unbind
```

这里的 **0000:04:00.0、0000:08:00.0、0000:09:00.0** 表示绑定到 e1000e 驱动上的 【pci 接口的 pci 号】。

**bind** 与 **new_id** 是绑定驱动过程中使用到的文件，**unbind** 是解绑驱动过程中使用到的文件。用户态看到的**绑定与解绑的过程就是向这几个文件中写入规定格式的数据操作。**

## 每个 /sys/bus/pci/drivers/ 子目录中不同 sys 文件的含义

linux kernel 源码目录中的 **ABI/testing/sysfs-bus-pci 详细描述了** /sys/bus/pci/drivers/ 子目录中不同 sys 文件的功能，摘录如下：

### 1. /sys/bus/pci/drivers/.../bind

```
		Writing a device location to this file will cause
		the driver to attempt to bind to the device found at
		this location.	This is useful for overriding default
		bindings.  The format for the location is: DDDD:BB:DD.F.
		That is Domain:Bus:Device.Function and is the same as
		found in /sys/bus/pci/devices/.  For example:
		# echo 0000:00:19.0 > /sys/bus/pci/drivers/foo/bind
		(Note: kernels before 2.6.28 may require echo -n).
```

这里写入的 0000:00:19.0 就是上面我们提到过的 pci 号。**对 bind 文件写入每一个接口的 pci 号意味着我们可以将一个网卡上的不同口绑定到不同的驱动上。**

### 2. /sys/bus/pci/drivers/.../unbind

```
		Writing a device location to this file will cause the
		driver to attempt to unbind from the device found at
		this location.	This may be useful when overriding default
		bindings.  The format for the location is: DDDD:BB:DD.F.
		That is Domain:Bus:Device.Function and is the same as
		found in /sys/bus/pci/devices/. For example:
		# echo 0000:00:19.0 > /sys/bus/pci/drivers/foo/unbind
		(Note: kernels before 2.6.28 may require echo -n).
```

这里向 **unbind** 文件写入接口的 pci 号就会解除当前绑定的驱动。一个接口可以不绑定到任何驱动上面，这种状态下接口不可用，一般不会这样去做。

### 3. /sys/bus/pci/drivers/.../new_id

```
		Writing a device ID to this file will attempt to
		dynamically add a new device ID to a PCI device driver.
		This may allow the driver to support more hardware than
		was included in the driver's static device ID support
		table at compile time.  The format for the device ID is:
		VVVV DDDD SVVV SDDD CCCC MMMM PPPP.  That is Vendor ID,
		Device ID, Subsystem Vendor ID, Subsystem Device ID,
		Class, Class Mask, and Private Driver Data.  The Vendor ID
		and Device ID fields are required, the rest are optional.
		Upon successfully adding an ID, the driver will probe
		for the device and attempt to bind to it.  For example:
		# echo "8086 10f5" > /sys/bus/pci/drivers/foo/new_id
```

向 **new_id** 中写入设备 id，将会动态的在指定的 pci 设备驱动中**添加一个新设备 id 列表**。这种功能允许驱动添加更多的硬件，能够动态扩充驱动支持的硬件设备列表。

**写入这个文件的格式中，Vendor Id 与 Device Id 字段是必须的，其它的字段可以不指定。**

成功添加一个设备 ID 时，驱动会尝试 probe 系统中匹配到的设备并尝试绑定到它之上。

### 4. /sys/bus/pci/drivers/.../remove_id

```
		Writing a device ID to this file will remove an ID
		that was dynamically added via the new_id sysfs entry.
		The format for the device ID is:
		VVVV DDDD SVVV SDDD CCCC MMMM.	That is Vendor ID, Device
		ID, Subsystem Vendor ID, Subsystem Device ID, Class,
		and Class Mask.  The Vendor ID and Device ID fields are
		required, the rest are optional.  After successfully
		removing an ID, the driver will no longer support the
		device.  This is useful to ensure auto probing won't
		match the driver to the device.  For example:
		# echo "8086 10f5" > /sys/bus/pci/drivers/foo/remove_id
```

remove_id 中写入的格式与 new_id 的写入格式相同。写入 remove_id 可以用来确保内核不会自动 probe 匹配到这个驱动的设备。

## dpdk 绑定、解绑网卡接口时的一些问题

### igb_uio pci 驱动支持的设备列表的特点

dpdk 老版本中最常使用的 pci 设备驱动是 **igb_uio**，我们经常需要将网卡接口绑定到这个驱动上来 bypass 原生内核驱动。

igb_uio 实现的功能与具体的硬件没有关系，所以它并没有添加任何支持的静态设备 id 列表，这表明初始状态下它是**不支持任何设备的。**

igb_uio 驱动与 pci 驱动类似，在其源码中可以找到如下 pci_driver 结构体。

```c
608 static struct pci_driver igbuio_pci_driver = {
609     .name = "igb_uio",
610     .id_table = NULL,
611     .probe = igbuio_pci_probe,
612     .remove = igbuio_pci_remove,
613 };
```

这里 **id_table** 设置为 NULL 表示驱动中没有静态添加任何支持的设备 id 列表，这意味着加载了 igb_uio 驱动后我们不能直接写入 bind 文件绑定驱动。

为了更清楚的说明这个 id_table，我使用 e1000e 驱动中的相关数据结构进行对比。下面是 e1000e 内核驱动中定义的 pci_driver 结构体的部分内容：

```c
7556 /* PCI Device API Driver */
7557 static struct pci_driver e1000_driver = {
7558     .name     = e1000e_driver_name,
7559     .id_table = e1000_pci_tbl,
7560     .probe    = e1000_probe,
.................................................
```

这里的 id_table 与 igb_uio 不同，它指向了 e1000_pci_tbl 这个数组。e1000_pci_tbl 数组的部分内容摘录如下：

```c
static const struct pci_device_id e1000_pci_tbl[] = {
	{ PCI_VDEVICE(INTEL, E1000_DEV_ID_82571EB_COPPER), board_82571 },
	{ PCI_VDEVICE(INTEL, E1000_DEV_ID_82571EB_QUAD_COPPER_LP),
	  board_82571 },
	.........................................................
	{ PCI_VDEVICE(INTEL, E1000_DEV_ID_82574L), board_82574 },
  .........................................................
```

我们看到在 **e1000_pci_tbl** 中有很多型号的网卡设备，82574L 是其中的一款。82574L 网卡对应的 Vendor Id 与 Device Id 在上述列表中，在驱动初始化的时候添加到了系统中，系统会自动探测并触发 probe 自动绑定，我们也可以操作 sys 文件手动绑定 82574L 网卡到 e1000e 驱动上。

### 先写入数据到 new_id 添加设备列表然后进行绑定

为了成功绑定接口到 **igb_uio** 上，我们首先需要在 igb_uio 中添加支持的设备，这个可以通过写入数据到 new_id 添加设备 id 完成。**注意同一个设备 id 可以多次写入 new_id 中，要移除也需要写入相同的次数到 remove_id 中，同时写入到 remove_id 并不会解除绑定。**

dpdk-17.04 中 [dpdk-devbind.py](http://dpdk-devbind.py/) 脚本中相关的代码如下：

```python
    if driver in dpdk_drivers:
        filename = "/sys/bus/pci/drivers/%s/new_id" % driver
        try:
            f = open(filename, "w")
        except:
            print("Error: bind failed for %s - Cannot open %s"
                  % (dev_id, filename))
            return
        try:
            f.write("%04x %04x" % (dev["Vendor"], dev["Device"]))
            f.close()
        except:
            print("Error: bind failed for %s - Cannot write new PCI ID to "
                  "driver %s" % (dev_id, driver))
            return

    # do the bind by writing to /sys
    filename = "/sys/bus/pci/drivers/%s/bind" % driver
    try:
        f = open(filename, "a")
    except:
        print("Error: bind failed for %s - Cannot open %s"
              % (dev_id, filename))
        if saved_driver is not None:  # restore any previous driver
            bind_one(dev_id, saved_driver, force)
        return
    try:
        f.write(dev_id)
        f.close()
```

上述代码首先写入 **new_id** 中添加设备 id 到 dpdk drivers（例如 igb_uio）中，然后将设备 pci 号写入 bind 文件来绑定驱动。

这样确保了首先有注册的设备 id，有了这个设备 id 总线才能够 match 到驱动执行 probe 操作。没有注册的设备 id，pci 总线不会匹配到指定的驱动，也无法将设备绑定到相应的驱动上。

实际上执行 ```echo "Vendor id device id" > new_id``` 命令的时候会触发总线 match，用 new_id 中的设备 id 匹配系统中的接口，将未绑定到任何驱动上的接口**自动绑定到对应的驱动上**。

**new_id 写入的参数中没有 pci 号，因此不能指定只绑定相同型号网卡的单个口到驱动中。除非其它口已经绑定到了其它驱动，不然这些口都会被绑定。**

### 绑定失败问题的排查

1. new_id 没有添加，不会 match 到指定的驱动
2. probe 过程异常，绑定失败
这种情况可以通过查看 dmesg 信息来分析定位。

## 写入 new_id 设备 id 触发总线匹配驱动自动 probe 问题

上文中提到过当写入设备 id 到 new_id 文件时会出触发总线 match 系统中的接口并对 match 到的接口执行驱动 probe 操作，那些与写入的设备 id 相同且没有绑定到任何驱动上的接口将会被自动绑定到该驱动上。

例如系统中有两个 82574L 网卡接口，都**没有绑定驱动**，这时我们写入 82574L 的设备 id 到 igb_uio 驱动对应的 new_id 文件中，会导致这两个口都被绑定到 igb_uio 上。

如果这种行为对功能有所影响，那么你可以选择在绑定到 igb_uio 之前先将接口绑定到其它驱动上（一般是官方驱动），这样在写入 new_id 文件时，已经绑定到其它驱动的接口就会被 skip。
