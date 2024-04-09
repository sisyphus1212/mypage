# 使用 mbuf 中的 headroom 与 tailroom
每个 mbuf 中 headroom 的大小与 tailroom 的大小在创建的时候就已经确定，
作用：主要用于在收包时将parse 出的matedate 放在其中

此时 mbuf 的 headroom 与 tailroom 就派上了用场。数通引擎中可以将解析报文得到的会被其它模块继续使用的字段存储到 mbuf 的 headroom、tailroom 中，其它模块、进程在获取到 mbuf 后，通过增加相应的偏移就能够获取到已经解析过程字段值。

## headroom 大小的问题
曾经在适配某 nxp dpaa2 网卡时，遇到 **headroom 大小限制**的问题。驱动、硬件中限制了 headroom 的大小不能超过 512，一旦超过就会收包异常，收到的报文都为 0。

我们的 dpdk 中配置的 headroom 大小超过了 512，这个大小是根据数通引擎中解析报文字段的需求设置的，**不能裁剪**。