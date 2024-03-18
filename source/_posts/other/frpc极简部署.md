---
title:  frpc极简部署
date: 2024-03-18 10:39:03
categories:
- [工具]
tags: frp
---

```shell
wget  https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.55.1/frp_0.55.1_linux_amd64.tar.gz
tar -xvf frp_0.55.1_linux_amd64.tar.gz
cp frp_0.55.1_linux_amd64/frpc /usr/local/bin/frpc
cat << eof >
```