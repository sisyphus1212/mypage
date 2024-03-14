---
title: centos内核切换
date: 2024-03-08 12:13:09
tags:
    - linux
    - centos
---

# 查看支持的repolist
```shell
dnf repolist all
```

# 查看repolist中存在的内核
```shell
sudo dnf --showduplicates list kernel
```

# 安装repolist中存在的内核
```shell
sudo dnf install kernel-4.18.0-305.3.1.el8
```

# 查看支持内核
```shell
grubby --info=ALL
```

# 查看支持内核
```shell
grubby --info=ALL
```

# 设置默认内核
```shell
sudo grubby --set-default /boot/vmlinuz-4.18.0-305.3.1.el8.x86_64
```