# 使用 mbuf 中的 headroom 与 tailroom
每个 mbuf 中 headroom 的大小与 tailroom 的大小在创建的时候就已经确定，
作用：主要用于在收包时将parse 出的matedate 放在其中

## headroom 大小的问题
曾经在适配某 nxp dpaa2 网卡时，遇到 **headroom 大小限制**的问题。驱动、硬件中限制了 headroom 的大小不能超过 512，一旦超过就会收包异常，收到的报文都为 0。

我们的 dpdk 中配置的 headroom 大小超过了 512，这个大小是根据数通引擎中解析报文字段的需求设置的，**不能裁剪**。

将 headroom 的位置移动到 tailroom 中，**减少 headroom 的大小，增加 tailroom 的大小**以同时满足网卡的硬件限制 headroom 不能超过 512 的问题及数通引擎需要使用超过 512 大小的空间存储解析 mbuf 得到的字段的问题。