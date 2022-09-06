# dpdk-16.04 根目录中 .git 目录对编译参数的影响
## 问题描述

在公司内部维护的 dpdk-16.04 目录中开发新功能时，编译遇到如下报错信息：

```bash
dpdk-16.04/lib/librte_eal/linuxapp/eal/eal_timer.c: In function ‘get_tsc_freq’:
dpdk-16.04/lib/librte_eal/linuxapp/eal/eal_timer.c:288:10: error: unused variable ‘test’ [-Werror=unused-variable]
   double test = 1.5/1.1;
          ^
cc1: all warnings being treated as errors
  CC rte_malloc.o
make[6]: *** [eal_timer.o] Error 1
make[6]: *** Waiting for unfinished jobs....
  CC malloc_elem.o
  CC malloc_heap.o
dpdk-16.04/lib/librte_eal/linuxapp/eal/eal_pci.c:442:6: error: no previous prototype for ‘adjust_logic_pci_scan’ [-Werror=missing-prototypes]
 void adjust_logic_pci_scan(void)
      ^
cc1: all warnings being treated as errors
make[6]: *** [eal_pci.o] Error 1
dpdk-16.04/lib/librte_eal/common/malloc_heap.c: In function ‘rte_eal_malloc_heap_init’:
dpdk-16.04/lib/librte_eal/common/malloc_heap.c:232:3: error: format ‘%d’ expects argument of type ‘int’, but argument 4 has type ‘size_t’ [-Werror=format=]
   printf("%s,%d,len=%d,pg=%d\n",__FUNCTION__,__LINE__,ms->len,ms->hugepage_sz);
```

仔细查看这些报错信息确定真正的问题是**警告被作为了错误处理**，一开始感觉有些奇怪，觉得不应该出这种问题，于是先对比正常编译的流程与出问题的编译流程中编译参数的区别。

## 成功与失败的数据对比

使用 make V=1 来编译，打印命令行信息。


成功编译时的命令行参数：
```
gcc -Wp,-MD,./.malloc_heap.o.d.tmp -m64 -pthread -fPIC  -march=core2 -DRTE_MACHINE_CPUFLAG_SSE -DRTE_MACHINE_CPUFLAG_SSE2 -DRTE_MACHINE_CPUFLAG_SSE3 -DRTE_MACHINE_CPUFLAG_SSSE3  -Idpdk-16.04/x86_64-native-linuxapp-gcc/include -include dpdk-16.04/x86_64-native-linuxapp-gcc/include/rte_config.h -Idpdk-16.04/lib/librte_eal/linuxapp/eal/include -Idpdk-16.04/lib/librte_eal/common -Idpdk-16.04/lib/librte_eal/common/include -Idpdk-16.04/lib/librte_ring -Idpdk-16.04/lib/librte_mempool -Idpdk-16.04/lib/librte_ivshmem -W -Wall -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations -Wold-style-definition -Wpointer-arith -Wcast-align -Wnested-externs -Wcast-qual -Wformat-nonliteral -Wformat-security -Wundef -Wwrite-strings -O3   -o malloc_heap.o -c dpdk-16.04/lib/librte_eal/common/malloc_heap.c
```

编译失败时的命令行参数：

```
gcc -Wp,-MD,./.malloc_heap.o.d.tmp -m64 -pthread -fPIC  -march=core2 -DRTE_MACHINE_CPUFLAG_SSE -DRTE_MACHINE_CPUFLAG_SSE2 -DRTE_MACHINE_CPUFLAG_SSE3 -DRTE_MACHINE_CPUFLAG_SSSE3  -Idpdk-16.04/x86_64-native-linuxapp-gcc/include -include dpdk-16.04/x86_64-native-linuxapp-gcc/include/rte_config.h -Idpdk-16.04/lib/librte_eal/linuxapp/eal/include -Idpdk-16.04/lib/librte_eal/common -Idpdk-16.04/lib/librte_eal/common/include -Idpdk-16.04/lib/librte_ring -Idpdk-16.04/lib/librte_mempool -Idpdk-16.04/lib/librte_ivshmem -W -Wall -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations -Wold-style-definition -Wpointer-arith -Wcast-align -Wnested-externs -Wcast-qual -Wformat-nonliteral -Wformat-security -Wundef -Wwrite-strings -Werror -O3   -o malloc_heap.o -c dpdk-16.04/lib/librte_eal/common/malloc_heap.c
```

对比发现编译失败时的命令行参数多了如下选项：

```bash
-Werror
```

gcc 官方手册中对 -Werror 的解释内容如下：

>-Werror Make all warnings into errors.

当开启了这个选项后所有的 warnings 都会被当作错误处理从而导致编译终止。

## 什么修改导致了编译参数变化？

排查如下可能的项目：

1. 源码修改无关联
2. 未修改环境变量
3. 未修改 mk 目录中编译脚本
4. config 文件未修改

经过这一通排查后没有找到问题，懵逼了几分钟后我想到了一个看上去没有关联的点——在内部维护的 dpdk-16.04 根目录中初始化 git 仓库。

我们的 dpdk-16.04 使用 svn 管理，为了开发方便，我就用 git 来管理代码修改。

重命名 .git 目录后，重新编译成功！


## dpdk-16.04 根目录中 .git 目录对编译参数的影响

确定了问题后，继续追问根本原因。直接在 mk 目录中使用 grep 搜索 .git，果然找到了相关的内容。

mk/rte.vars.mk 中如下语句会判断 .git 目录是否存在来设定 RTE_DEVEL_BUILD 变量。

```Makefile
# developer build automatically enabled in a git tree
ifneq ($(wildcard $(RTE_SDK)/.git),)
RTE_DEVEL_BUILD := y
endif
```

RTE_DEVEL_BUILD 变量在 toolchain/gcc/rte.vars.mk 中被判断，当为 y 的时候就在 WERROR_FLAGS 中添加 -Werror 参数。相关代码如下：


```Makefile
ifeq ($(RTE_DEVEL_BUILD),y)
WERROR_FLAGS += -Werror
endif
```

## 总结

很多时候问题一直都存在，只不过你并不一定能够发现它。当问题有一天跳出来，可能会让你大吃一惊。遇到一个问题时，在解决问题的同时尽可能向下挖掘，在这一过程中也许你能够发现新的问题，继续追问这些问题你将收获更多的成长。




