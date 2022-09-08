# dpdk 问题分析：dpdk-20.11 ice 100G 网卡 rss_hash 配置无效问题
## 问题描述
使用 dpdk-20.11 testpmd 测试 ice 100G 网卡的时候发现设置 rss_hash 一直不生效，打流确认流量一直被 hash 到第一个队列上，其它的队列没有收到一个包。

## 问题排查过程
1. 排查流量的配比

	确认流量的五元组在一定范围内变化，排除流量问题。
2. 检查 testpmd 多队列配置

	确认多队列配置生效。

3. 检查 rss_hash key 配置
	使用默认 rss_hash key 与对称 rss_hash key 都不能成功 hash。

## 检索互联网
### ice 网卡 DDP 固件包

A general purpose DDP package is automatically installed with all supported 800 Series drivers on Windows, ESX, FreeBSD, and Linux operating systems, including those provided by the Data Plane Development Kit (DPDK). This general purpose DDP package is known as the OS-Default package. Additional DDP packages will be available to address packet processing needs for specific market segments. For example, a telecommunications (Comms) DDP package has been developed to support GTP and PPPoE protocols in addition to the protocols in the OS-Default package. The Comms DDP package is available with DPDK 19.11 and will also be supported by the 800 Seriesice driver on Linux operating systems


### Safe mode

In pre-boot or if a DDP package is not loaded by an OS driver, the 800 Series is configured in safe mode via an NVM-default configuration that is automatically loaded by firmware. This configuration supports a minimum set of protocols and allows basic packet handling in the pre-boot environment, such as PXE boot or UEFI. The device can also be configured in safe mode if the DDP package fails to load due to a software incompatibility or other issue. If an OS driver loads and cannot load a DDP package, a message is printed in the system log that the device is now in safe mode.In this safe mode, the driver disables support for the following features:

1. Multi-queue
2. Virtualization (SR-IOV/VMQ)
3. Stateless workload acceleration for tunnel overlays(VxLAN/Geneve)
4. RDMA (iWARP/RoCE)
5. RSC
6. RSS
7. DCB /DCBx
8. Intel® Ethernet Flow Director
9. QinQ
10. XDP / AF-XDP
11. ADQ

## 真正的问题
当 ice 100G 网卡初始化的时候未成功加载 DDP 时，驱动会进入安全模式，在此模式下 rss、多队列都被关闭。

## 解决方法
下载官方推荐的 ddp 包并复制到 lib/firmware/intel/ice/ddp 目录中，重新启动 testpmd，问题得到解决。

