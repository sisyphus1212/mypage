# at803x phy 驱动关闭节能模式
## 问题描述
某使用外接 phy 的网卡，当不插网线的时候接口不能识别，插上网线的时候正常工作。

## 从数据手册入手
出问题的 phy 型号为 AR8035，其 datasheet 下载地址如下：

[AR835.pdf](https://www.redeszone.net/app/uploads-redeszone.net/2014/04/AR8035.pdf)

手册中与这个问题相关的描述内容摘录如下：

```
The AR8035 supports hibernation mode. When the cable is unplugged, the AR8035 will enter
hibernation mode after about 10 seconds. The power consumption in this mode can go as 
low as 10mW only when compared to the normal mode of aperation. When the cable is re-
connected, the AR8035 wakes up and normal functioning is restored
```
上面的描述说明 AR8035 phy 支持休眠模式。当网线被拔掉后，AR8035 将会在 10 秒后进入休眠模式。在这个模式下与正常工作相比，电量消耗将会降低到 10mW 之下。当线重新连接后，AR8053 将会唤醒，恢复正常运行状态。

根据这个说明只需要关闭这个休眠模式应该就能够解决问题。
## 如何关闭 AR8035 phy 的休眠模式？

从手册中找到了下面的内容：
![在这里插入图片描述](https://img-blog.csdnimg.cn/20201215214318768.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)
只需要将偏移量为 B 的 Hib 控制寄存器的第 15 位清零就可以了，在 phy probe 的时候设定这个寄存器，修改代码进行测试，确定问题得到解决。

