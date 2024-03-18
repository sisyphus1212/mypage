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
cat << eof > /usr/lib/systemd/system/frpc.service
[Unit]
Description=frps server daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /usr/share/frp/frpc.ini
KillMode=process
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
eof

echo << eof >  /usr/share/frp/frpc.ini
[common]
#server_addr = 192.168.2.71
#server_port = 7000
#token = b9eb1007-2d57-4225-951b-d5883134fc35
server_addr="117.50.175.8"
server_port =8010
token =99c18640-3481-4977-9f85-fb69037f327p
[ssh_1]
type = tcp
local_ip = 0.0.0.0
local_port = 65078
remote_port = 9022
[vnc_1]
type = tcp
local_ip = 0.0.0.0
local_port = 5901
remote_port = 9021
eof

```