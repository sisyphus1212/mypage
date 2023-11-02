# dpdk kni 口 ifconfig up down 的执行流程
## 问题描述
用户执行 ifconfig netcard down、up 时 rte_kni 模块中的哪部分起作用？

## ifconfig up down 接口的正常流程
ifconfig 是通过调用 ioctl 来完成工作的。期间经过了一系列的函数，最终调用到的是在网卡驱动在 netdev 中注册的 netdev_ops 虚函数表中的函数指针。

netdev_ops 虚函数表中与 up 、down 相关的虚函数如下：

	ndo_open
	ndo_close

## dpdk 中 kni 口 ifconfig up down 的不同流程
dpdk kni 中并不会调用 ndo_open、ndo_start 虚函数接口，它会发送一个控制命令到用户态程序中，用户态程序接收到这个控制命令后，判断命令的类型，然后调用 pmd 中实现的 start 与 stop 函数来完成 up、down。

## dpdk 中 kni 模块 ifconfig up down 的具体流程
kni 模块中关联的函数是 kni_net_open 与 kni_net_close，这两个函数在 kni_net.c 中被定义。

进一步的分析上面提到的两个函数发现它们会调用 **kni_net_process_request** 来通过共享队列的方式向 dpdk 的用户态程序发送命令，真正的 up、down 实际是在用户态程序中完成的。

## dpdk 用户态程序注册的 rte_kni_ops 结构
dpdk 用户态程序需要预先注册一个 rte_kni_ops 结构，相关的代码如下：

```c
  	ops.config_network_if = kni_config_network_interface;
    ops.set_ethtools_cmd = kni_set_ethtool;
    .........
```
这个 ops 作为 rte_kni_alloc 函数的第三个参数传入到 dpdk 中。

这里需要关注的是 **kni_config_network_interface** 这个函数。这个函数中会完成网络设备的 up 与 down。

dpdk-19.11 examples 中的 kni 代码中就是 kni_config_network_interface 的标准实现。

其代码如下：

```c
/* Callback for request of configuring network interface up/down */
static int
kni_config_network_interface(uint16_t port_id, uint8_t if_up)
{
    int ret = 0; 

    if (!rte_eth_dev_is_valid_port(port_id)) {
        RTE_LOG(ERR, APP, "Invalid port id %d\n", port_id);
        return -EINVAL;
    }    

    RTE_LOG(INFO, APP, "Configure network interface of %d %s\n",
                    port_id, if_up ? "up" : "down");

    rte_atomic32_inc(&kni_pause);

    if (if_up != 0) { /* Configure network interface up */
        rte_eth_dev_stop(port_id);
        ret = rte_eth_dev_start(port_id);
    } else /* Configure network interface down */
        rte_eth_dev_stop(port_id);

    rte_atomic32_dec(&kni_pause);

    if (ret < 0) 
        RTE_LOG(ERR, APP, "Failed to start port %d\n", port_id);

    return ret; 
}
```
可以看到它实际是调用 **rte_eth_dev_stop、rte_eth_dev_start** 来完成接口的 up、down。
## rte_kni_handle_request
上文中我提到 kni 会通过共享队列发送一个控制消息到用户态，在 dpdk 用户态程序中需要轮询获取 kni 共享队列中的消息，这一般是在收发包间隙或者单独创建的一个管理线程中执行的。

其核心逻辑是调用 **rte_kni_handle_request** 函数进行处理。dpdk-19.11 中该函数的实现部分内容截取如下：

```c
int
rte_kni_handle_request(struct rte_kni *kni)
{
    unsigned int ret;
    struct rte_kni_request *req = NULL;

    if (kni == NULL)
        return -1; 

    /* Get request mbuf */
    ret = kni_fifo_get(kni->req_q, (void **)&req, 1); 
    if (ret != 1)
        return 0; /* It is OK of can not getting the request mbuf */

    if (req != kni->sync_addr) {
        RTE_LOG(ERR, KNI, "Wrong req pointer %p\n", req);
        return -1; 
    }   

    /* Analyze the request and call the relevant actions for it */
    switch (req->req_id) {
    case RTE_KNI_REQ_CHANGE_MTU: /* Change MTU */
        if (kni->ops.change_mtu)
            req->result = kni->ops.change_mtu(kni->ops.port_id,
                            req->new_mtu);
        break;
    case RTE_KNI_REQ_CFG_NETWORK_IF: /* Set network interface up/down */
        if (kni->ops.config_network_if)
            req->result = kni->ops.config_network_if(kni->ops.port_id,
                                 req->if_up);
        break;
```
上述代码中 **kni_fifo_get** 负责从共享队列中获取消息，获取成功后校验消息是否合法，合法的消息则根据 req_id 进行分发，```RTE_KNI_REQ_CFG_NETWORK_IF```类型的消息会调用 kni 初始化中注册的 ops 中的 config_network_if 接口来处理。

## 总结
对 dpdk kni 口执行 ifconfig up down 操作会涉及内核与用户态的通信，kni 共享队列实现了内核与用户态的一种高效的通信方式。可以看到对 dpdk kni 口执行 up、down 其流程与普通的网卡驱动处理方式不同，实际是调用用户态的 pmd 驱动来完成的。





