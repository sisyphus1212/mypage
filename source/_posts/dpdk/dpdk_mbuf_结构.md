---
---

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
