---
title: dpdk_vdpa热迁移-脏页标记.md
date: 2022-03-19 10:55:27
categories:
- [dpdk]
tags:
- dpdk
- 网络开发
---

```c
static __rte_always_inline void
vhost_log_page(uint8_t *log_base, uint64_t page)
{
	vhost_set_bit(page % 8, &log_base[page / 8]);
}
```