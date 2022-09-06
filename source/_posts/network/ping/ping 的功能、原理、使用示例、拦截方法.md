# ping 的功能、原理、使用示例、拦截方法
## ping 的功能及其工作原理
ping 一般用来检测网络链路是否连通以及到达目的网络节点中间的延时。ping 程序会向服务器端发送 icmp 的 ECHO_REQUEST 包，服务器接收到此 icmp 包后会返回一个 ECHO_REPLY icmp 包，根据这些返回的信息就可以简单判断服务器的状态与网络延时的情况。

## ping 的演示
```sh
longyu@longyu-pc:~$ ping www.baidu.com
PING www.a.shifen.com (61.135.169.125) 56(84) bytes of data.
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=1 ttl=128 time=36.9 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=2 ttl=128 time=37.10 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=3 ttl=128 time=37.4 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=4 ttl=128 time=37.5 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=5 ttl=128 time=37.6 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=6 ttl=128 time=37.5 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=7 ttl=128 time=36.7 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=8 ttl=128 time=36.1 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=9 ttl=128 time=36.0 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=10 ttl=128 time=37.4 ms
64 bytes from 61.135.169.125 (61.135.169.125): icmp_seq=11 ttl=128 time=39.3 ms
^C
--- www.a.shifen.com ping statistics ---
11 packets transmitted, 11 received, 0% packet loss, time 32ms
rtt min/avg/max/mdev = 36.031/37.312/39.347/0.870 ms
```
## ping 被拦截的情况
在一些情况下，ping 不通服务器可能并不意味着服务器宕机。通过 ping 我们无法确定是中间链路的问题还是目标服务器的问题。我就遇见过 ping 不通，但是却可以 ssh 成功的情况。这种情况意味着 ping 程序发出的 icmp 包在发送给服务器端、服务器端返回数据给本地时出现了问题。**可能是发不出去，也可能是接收不进来，这是两个大方向上的问题。**

## 如何查看谁在 ping 我呢？
tcpdump、wireshark 监测网口收到的 icmp 包，解码 icmp 包便可以得到发送端的 ip 地址。使用 tcpdump 的方式可以参考如下命令：

```sh
sudo tcpdump 'icmp[icmptype] == icmp-echo'
sudo tcpdump 'icmp[icmptype] == icmp-echoreply'
```

## 如何忽略 icmp ECHO_REQUEST 请求呢？
主要有两种方式：

1. 更改内核参数
2. 添加防火墙配置

具体的配置请访问：[Getting Linux to ignore pings](https://www.networkworld.com/article/3228127/getting-linux-to-ignore-pings.html)



