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

