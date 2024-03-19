---
title: dpdk 编译
date: 2023-03-19 10:55:27
tags: dpdk
---

# meson ninja 安装
```shell
# 方法1：
yum install ninja-build

# 方法2：
wget https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip
python3 -m pip install meson

# 方法3：
python3 -m pip install meson
python3 -m pip install ninja
```

# dpdpk 编译
## 无脑编译
```shell
meson build
cd build
ninja
meson install
ldconfig
```

## 调整构建选项
```shell
meson setup -Dexamples=l2fwd,l3fwd build
meson setup -Dc_args='-m32' -Dc_link_args='-m32' build

两种方式：
1. 最初配置build文件夹时传递：meson setup -Dbuildtype=debug build
2. 配置build文件夹后传递：meson configure -Dbuildtype=debug
```