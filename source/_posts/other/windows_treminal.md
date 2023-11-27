---
title: windows terminal技巧
date: 2022-08-29 18:21:45
categories:
- [其它, 方法分享]
tags: 其它
---
windows terminal 配合 wsl 可以玩出很多技巧来：

# ssh密码登录 和 sftp支持

```shell
wsl -e sshpass -p lcj@ps-aux sftp -P 12345 root@10.0.25.19
wsl -e sshpass -p lcj@ps-aux ssh -t root@10.0.25.19 -p 12345
```

![1701065028724](../../../medias/images_0/windows_treminal/1701065028724.png)
