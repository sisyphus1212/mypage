---
title:  ssh极简内网穿透
date: 2023-03-18 10:39:03
categories:
- [工具]
tags:
    - ssh
    - 内网穿透[Unit]
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
---
# 服务端
```sh
sudo sed -i '/GatewayPorts no/a GatewayPorts yes' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

# 客户端
```sh
cat << eof >  ssh
[Unit]
Description=frps server daemon
After=network.target

[Service]
Type=simple
ExecStart=sshpass -p lcj@ps-aux ssh -R 8088:localhost:65078 lcj@192.168.2.71
KillMode=process
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

