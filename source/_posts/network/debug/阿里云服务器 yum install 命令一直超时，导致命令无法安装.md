# 阿里云服务器 yum install 命令一直超时，导致命令无法安装
## 问题描述
如下图所示，使用 yum install 安装一些开发工具包的时候，使用阿里云自己
的镜像仓库会超时，导致安装失败。

![yum install 超时](https://img-blog.csdnimg.cn/20201023080527888.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70#pic_center)
## 排查过程
### 根据过去的经验进行排查
1. 是否某个包的问题

	单独执行，安装一条命令如 **yum install gcc**，发现仍旧有相同的问题。

2. 修改 /etc/resolv.conf

	修改为自动生成的域名后发现镜像仓库域名解析失败，改回去后，ping 域
	名能够 ping 通，延时也在正常范围内（1ms），排除这个影响。
3. 关闭 selinux 

	运行 setenforce 0 关闭 selinux 后，仍旧有问题

4. 查看 iptables 信息

	iptables --list 查看，确认本地服务器 iptables 中没有阻断规则
### 借助搜索引擎进行排查
百度搜索得到了两方面的信息：

1. 源的问题
2. dns 配置的问题

第二点已经排除，第一点通过尝试更换 163 源来测试，确认也有问题，
说明问题应该在本地。同时注意到有些链接中提示可以清空源缓存，
尝试了下发现没有结果

### strace 大法
使用 strace yum install gcc 跟踪，确定出问题的点。

当**第一次**打印出延时信息后按 **Control+C**，按了这个键之后打印出
**在获取某个 xml 文件的时候失败了**，有看到是**调用 curl 来获取**的。

再次 strace ，注意到如下输出信息：

```strace
socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 7
fcntl(7, F_GETFL)                       = 0x2 (flags O_RDWR)
fcntl(7, F_SETFL, O_RDWR|O_NONBLOCK)    = 0
connect(7, {sa_family=AF_INET, sin_port=htons(80), sin_addr=inet_addr("100.100.2.148")}, 16) = -1 EINPROGRESS (Operation now in progress)
poll([{fd=7, events=POLLOUT|POLLWRNORM}], 1, 0) = 0 (Timeout)
poll([{fd=7, events=POLLOUT}], 1, 1000) = 0 (Timeout)
poll([{fd=7, events=POLLOUT|POLLWRNORM}], 1, 0) = 0 (Timeout)
poll([{fd=7, events=POLLOUT}], 1, 1000) = 0 (Timeout)
```
这里要连接到 100.100.2.148 的 **80 端口**，**connect 返回了 -1**，实际的错误信息为 **EINPROGRESS（操作正在处理）**。

man connect 获取到如下信息： 

```manual
       EINPROGRESS
              The socket is nonblocking and the connection cannot be completed immediately.  It is possible to select(2) or poll(2) for completion
              by selecting the socket for writing.  After select(2) indicates writability, use getsockopt(2) to read the SO_ERROR option at  level
              SOL_SOCKET  to determine whether connect() completed successfully (SO_ERROR is zero) or unsuccessfully (SO_ERROR is one of the usual
              error codes listed here, explaining the reason for the failure).
```
这个错误值表明 socket 处于**非阻塞模式下**(strace 的输出可以看到程序使用了 **fcntl** **将 socket 设定为了非阻塞模式**) 且**连接不能立刻完成**，连接建立的完成**延迟到** select、poll 中监听 socket 来写数据时。当 select 表明可以写的时候，使用 **getsockop**t 来在 **SOL_SOCKET 层面**读取 **SO_ERROR** 选项确定是否**连接成功完成。**

## 分析结论
根据这些信息，看来应该是**远端服务器拒绝了本地服务器的访问请求**，可能是 **80 端口被阻断了**，排查发现确实是这个原因，本地服务器由于之前中过挖矿病毒，有异常流量导致 80 端口暂时被阿里云平台阻断，解封后 yum install 正常运行。

## tcpdump 抓包的数据佐证
在此期间，通过 **tcpdump** 抓取 yum install gcc 命令发出的报文，发现本地发了初始化连接的 tcp 报文后，远端服务器一直没有回 ack，然后超时重传三次，都没有回应，连接就断开了。

wireshark 解析报文内容，得到了如下信息：

![tcp 超时重传](https://img-blog.csdnimg.cn/20201023081938833.jpg?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70#pic_center)
这里第一条报文由**本地服务器**发向 100.100.2.148 这个镜像仓库的服务器，在超时时间内没有收到 ack，**tcp 协议栈开始重传**，第 1 s 左右重传第一次，仍旧没有收到 ack，第 3s 左右重传第二次，仍旧没有收到，第 7 s 左右重传第三次，仍旧没有收到 ack 消息，连接直接断开，然后 yum 尝试使用其备选镜像仓库，目的 ip 有变化。

根据 tcpdump 抓包信息，看来问题可能出在本地发包到镜像仓库这一过程中、镜像仓库回应 ack 这一过程中，直接 ping 镜像仓库的地址发现能够 ping 通，说明本地服务器到镜像仓库服务器所在的网络是联通的，不存在网络故障的原因。

那么只可能有两方面的原因：

1. 本地服务器没有真正发出、收到相应的包
2. 远端服务器没有真正发出、收到相应的包

这里远端服务器对应的是阿里云仓库，是我们不能直接观测的数据，我们可以先排除本地服务器的问题，确认没有问题后再排查远端服务器的问题，这可以通过客服、检查 web 管理页面中的消息来完成。

