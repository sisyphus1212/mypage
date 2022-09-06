# ethtool 修改网卡 eeprom 内容
## 问题描述
在解决工作中遇到的一个问题时，有对比出出问题的设备网卡的 eeprom 与其它相同固件版本厂商的相同网卡的 eeprom 内容存在区别。

通过阅读手册，发现区别并不只是那些接口特定的信息，如 mac 地址、device id 等等，还有一些与配置相关的内容，怀疑可能有影响，需要**修改**出问题设备的 **eeprom** 中的相关内容进行测试。

## 使用虚拟机进行模拟
以前没有修改过 eeprom 内容，只是了解过可以通过 ethtool 命令来 dump eeprom 信息。在 ethtool 命令帮助信息中查找，发现它也可以修改 eeprom 的内容。

不过直接修改物理网卡的 eeprom 可能会把网卡刷成砖，就先使用虚拟机模拟了下。

### 获取驱动与固件版本信息
使用 82574 虚拟网卡，驱动与固件版本信息如下：

```bash
longyu@virt-debian10:~$ sudo ethtool -i enp9s0
driver: e1000e
version: 3.2.6-k
firmware-version: 2.1-0
expansion-rom-version: 
bus-info: 0000:09:00.0
supports-statistics: yes
supports-test: yes
supports-eeprom-access: yes
supports-register-dump: yes
supports-priv-flags: no
```
## man ethtool
man ethtool 获取到了如下与 eeprom 相关的命令行选项描述信息：
```c
       -e --eeprom-dump
              Retrieves and prints an EEPROM dump for the specified network device.  When raw is enabled, then it dumps the raw EEPROM data to stdout.  The  length  and
              offset parameters allow dumping certain portions of the EEPROM.  Default is to dump the entire EEPROM.

           raw on|off

           offset N

           length N

       -E --change-eeprom
              If  value  is  specified,  changes  EEPROM byte for the specified network device.  offset and value specify which byte and it's new value. If value is not
              specified, stdin is read and written to the EEPROM. The length and offset parameters allow writing to certain portions of the EEPROM.  Because of the per‐
              sistent nature of writing to the EEPROM, a device-specific magic key must be specified to prevent the accidental writing to the EEPROM.
```

### -e 选项
-e 选项用于 dump eeprom 内容，可以指定 dump 的偏移量与基地址，同时 dump 的输出格式支持 raw 与非 raw 的格式，这两个格式的区别很容易通过实际执行发现。

```bash
longyu@virt-debian10:~$ sudo ethtool -e  enp9s0 raw on | od -x
0000000 5452 0800 ef3f 0420 f746 2010 ffff ffff
0000020 0000 0000 026b 10d3 8086 10d3 0000 8058
0000040 0000 2001 7e7c ffff 1000 00c8 0000 2704
0000060 6cc9 3150 070e 460b 2d84 0100 f000 0706
0000100 6000 0080 0f04 7fff 4f01 c600 0000 20ff
0000120 0028 0003 0000 0000 0000 0003 0000 ffff
0000140 0100 c000 121c c007 ffff ffff ffff ffff
0000160 ffff ffff ffff ffff 0000 0120 ffff 8dd8
0000200

longyu@virt-debian10:~$ sudo ethtool -e  enp9s0 raw off
Offset		Values
------		------
0x0000:		52 54 00 08 3f ef 20 04 46 f7 10 20 ff ff ff ff 
0x0010:		00 00 00 00 6b 02 d3 10 86 80 d3 10 00 00 58 80 
0x0020:		00 00 01 20 7c 7e ff ff 00 10 c8 00 00 00 04 27 
0x0030:		c9 6c 50 31 0e 07 0b 46 84 2d 00 01 00 f0 06 07 
0x0040:		00 60 80 00 04 0f ff 7f 01 4f 00 c6 00 00 ff 20 
0x0050:		28 00 03 00 00 00 00 00 00 00 03 00 00 00 ff ff 
0x0060:		00 01 00 c0 1c 12 07 c0 ff ff ff ff ff ff ff ff 
0x0070:		ff ff ff ff ff ff ff ff 00 00 20 01 ff ff d8 8d 
```
可以看到 raw 格式开启后，dump 出的内容没有进行任何处理，这里我用 od -x 来转化了下，不然它会**输出一堆乱码**。

raw 格式关闭后，dump 出的内容进行了格式化，与 od -x 输出的格式类似。**默认关闭 raw 格式。**

同时值得一提的是 eeprom 的前六个字节表示的是**网卡的 mac 地址**，这点可以通过执行 ifconfig 来确认。

```bash
longyu@virt-debian10:~$ sudo ifconfig enp9s0
enp9s0: flags=4098<BROADCAST,MULTICAST>  mtu 1500
        ether 52:54:00:08:3f:ef  txqueuelen 1000  (Ethernet)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
        device interrupt 23  memory 0xfc240000-fc260000  
```
可以看到 ifconfig 看到的接口的 mac 地址为 52:54:00:08:3f:ef 正好对应 eeprom 中的前 6 个字节。

### offset 与 length 参数
我们也可以指定 offset 与 length 来观察 ethtool 命令的输出，一个示例如下：

```bash
longyu@virt-debian10:~$ sudo ethtool -e enp9s0 offset 0 length 1
Offset		Values
------		------
0x0000:		52 
longyu@virt-debian10:~$ sudo ethtool -e enp9s0 offset 1 length 1
Offset		Values
------		------
0x0001:		54 
```
上述示例中，第一个命令行指定了 offset 为 0，长度为 1，dump 出的就是 eeprom 中的第 0 字节处的值；第二个命令行指定了 offset 为 1，长度为 1，dump 出的就是 eeprom 中的第 1　个字节处的值。
 
 这里值的一提的是 eeprom 的内容通常是**以字为单位**的，一个字表示**两个字节**的内容，其内部一般是通过 i2c 总线来读取 eeprom 信息的，**而 i2c 总线读取的单位就是字，手册中也是以字为单位描述不同字段的含义的。**
 
### -E 选项 
上文中与 -E 选项相关的 manual 中的描述信息明确指出，为了避免意外写入 eeprom 造成的问题，修改 eeprom 内容时需要指定一个**设备特定的 magic**，这个 magic 一般是**设备的 vendor 与 device id 的组合**，同时 offset 与 length 参数让我们能够修改指定位置处的指定长度的 eeprom 内容。

关于 magic 校验内容，我们可以从 e100e 驱动中 set_eeprom 的函数数中找到相关的内容。

相关代码摘录如下：
```c
static int e1000_set_eeprom(struct net_device *netdev,
			    struct ethtool_eeprom *eeprom, u8 *bytes)
{
	struct e1000_adapter *adapter = netdev_priv(netdev);
	struct e1000_hw *hw = &adapter->hw;
	u16 *eeprom_buff;
	void *ptr;
	int max_len;
	int first_word;
	int last_word;
	int ret_val = 0;
	u16 i;

	if (eeprom->len == 0)
		return -EOPNOTSUPP;

	if (eeprom->magic !=
	    (adapter->pdev->vendor | (adapter->pdev->device << 16)))
		return -EFAULT;
```
可以看到这里 magic 的值会与高十六位的 device id 与低十六位的 vendor id 比较，不一致则直接返回。

这意味着我们指定的 magic 内容应该类似 15338086 (I210 网卡) 这样的值，在我的测试环境中 82574L 网卡对应的 magic 内容为 0x10d38086。

一个具体的示例如下：

```bash
longyu@virt-debian10:~$ sudo ethtool -e enp9s0  offset 0 length 1 
Offset		Values
------		------
0x0000:		52 
longyu@virt-debian10:~$ sudo ethtool -E enp9s0 magic 0x10d38086 offset 0 length 1 value 0xFF
longyu@virt-debian10:~$ sudo ethtool -e enp9s0  offset 0 length 1 
Offset		Values
------		------
0x0000:		ff 
```
可以看到，在修改前 eeprom 0 字节处内容为 52，修改后值变为了 FF，修改成功。

如果你这时候 dump 所有的 eeprom 内容与旧的内容进行对比，你会发现还有其它你没有修改的地方的值也产生了变化，这里应该是 eeprom 的 **checksum** 字段的变化。

eeprom 内容更新后，**checksum 内容**也需要随之更新。checksum 一般在网卡初始化的过程中被用来校验 eeprom 时候有效。

## strtoull 函数将字符串转化为整数值

对于这里 magic、offset、length、value 等参数指定的值的格式，通过阅读 ethtool 代码，我发现它们都是用 strtoull 函数来将字符串转化为整数值的。


```
      The  strtoul() function converts the initial part of the string in nptr to an unsigned 
      long int value according to the given base, which must be between 2 and 36 
      inclusive, or be the special value 0.

      The string may begin with an arbitrary amount of white space (as determined by 
      isspace(3)) followed by a single optional '+' or '-' sign.  If base is zero or 16,
      the  string  may then include a "0x" prefix, and the number will be read in base
      16; otherwise, a zero base is taken as 10 (decimal) unless the next character is
      '0', in which case it is taken as 8 (octal).
```
ethtool 命令中获取 magic、offset、length、value 参数的值，核心是通过调用如下函数：

```c
stroull(str, &endp, 0)
```
这里 base 为 0 是一个特殊的设定，根据上面 manual 中的说明，它可以使用 0x 前缀标识出的 16 进制格式，也可以使用 10 进制格式，或者以 0 标志的 8 进制格式。

## 其它的设定 eeprom 内容的方式
除了 ethtool 设定 eeprom 内容之外，我们也可以制作一个 dos 盘引导系统，使用 eepudate 命令来获取、更新 eeprom，这种方式相对麻烦一点。

