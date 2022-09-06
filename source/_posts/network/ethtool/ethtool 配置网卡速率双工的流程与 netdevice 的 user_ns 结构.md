# ethtool -s 配置网卡速率双工的流程与 netdevice 的 user_ns 结构
## strace 跟踪 ethtool -s 执行过程
```c
socket(AF_INET, SOCK_DGRAM, IPPROTO_IP) = 3
ioctl(3, SIOCETHTOOL, 0x7ffdb4348f80)   = -1 EOPNOTSUPP (Operation not supported)
ioctl(3, SIOCETHTOOL, 0x7ffdb4348f80)   = 0
ioctl(3, SIOCETHTOOL, 0x7ffdb4348f80)   = 0
```

## ethtool 程序代码中的三次 ioctl 的处理过程

![在这里插入图片描述](https://img-blog.csdnimg.cn/046e605ed8de4429981653415309573b.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)

## 内核 ethtool ioctl 执行子流程
内核源码 **net/core/ethtool.c** 中 **dev_ethtool** 函数负责【分发】 **SIOCETHTOOL** 子命令，根据子命令对 netdev 中 ethtool_ops 虚函数表的相关函数进行调用。

分发逻辑使用 switch 语句实现，部分代码摘录如下：
```c
/* Allow some commands to be done by anyone */
        switch (ethcmd) {
        case ETHTOOL_GSET:
        case ETHTOOL_GDRVINFO:
        case ETHTOOL_GMSGLVL:
        case ETHTOOL_GLINK:
        .........
        case ETHTOOL_GET_TS_INFO:
        case ETHTOOL_GEEE:
                break;
        default:
                if (!ns_capable(net->user_ns, CAP_NET_ADMIN))
                        return -EPERM;
        }
```
在上面的流程中，dev_ethtool 会对 ethool 的一些 SET 子命令进行【权限检查】，拥有 **CAP_NET_ADMIN** 权限才允许继续执行，缺少此权限则立即返回 -EPERM。

这里的检查意味着普通用户只能通过 ethtool 【获取】接口信息而不能设置接口状态，增强了安全性。

## 内核代码中 net->user_ns 在哪里被赋值？
内核代码中，**net->user_ns** 在 **setup_net** 中赋值，**setup_net** 在 **copy_net_ns** 中被赋值。进一步分析确定只有当需要创建新的命令空间时 **copy_net_ns** 才会被调用。

copy_namespace 函数中会判断上层传入的 flags 是否设定了 CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWPID | CLONE_NEWNET 中的标志，未设定则不创建新的 namespace，对于子进程来说，**此部分数据结构完全拷贝自父进程**。

## 如何获取到当前进程所在的 namespace？

搜索了一下确定，可以通过访问 /proc/pid/ns/ 目录确定每个进程归属的不同 namespace。

测试记录如下：

```c
longyu@debian: $ ls -lh /proc/$$/ns/
total 0
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 cgroup -> 'cgroup:[4026531835]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 ipc -> 'ipc:[4026531839]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 mnt -> 'mnt:[4026531840]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 net -> 'net:[4026531992]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 pid -> 'pid:[4026531836]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 pid_for_children -> 'pid:[4026531836]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 user -> 'user:[4026531837]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:08 uts -> 'uts:[4026531838]'
longyu@debian: $ top &
[1] 19567
longyu@debian: $

[1]+  Stopped                 top
longyu@debian: $ ls -lh  /proc/19567/ns/
total 0
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 cgroup -> 'cgroup:[4026531835]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 ipc -> 'ipc:[4026531839]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 mnt -> 'mnt:[4026531840]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 net -> 'net:[4026531992]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 pid -> 'pid:[4026531836]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 pid_for_children -> 'pid:[4026531836]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 user -> 'user:[4026531837]'
lrwxrwxrwx 1 longyu longyu 0 Jul 22 06:09 uts -> 'uts:[4026531838]'
```
上述测试示例中，两个程序的 namespace 相同。

