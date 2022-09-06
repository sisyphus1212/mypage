# dpdk 中 rte_config.h 配置文件生成的问题
## 为什么要生成 rte_config.h 头文件
dpdk 有单独的一套 config 配置文件，在 RTE_TARGET 变量指定的目标目录下需要生成一个 .config 文件，这个 .config 文件用来配置 dpdk 中不同组件的功能。

dpdk 大部分代码都是用 C 语言编写的，不能够直接使用 .config 文件。在 dpdk 编译过程中会根据 RTE_TARGET 变量指定的目标目录中的 .config 文件生成 rte_config.h 文件，dpdk 内部实际是使用 rte_config.h 文件工作的。

## dpdk 编译过程中生成 RTE_TARGET 目录中的 include 目录
dpdk 编译时首先会在 include 目录中生成需要使用的头文件，一个标准的目录内容如下：
![在这里插入图片描述](https://img-blog.csdnimg.cn/20200805105306287.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)从上图中可以发现 rte_config.h 文件的颜色与其他文件、目录的颜色不同，这里 ls 用不同的颜色标注了不同的文件类型。

rte_config.h 是个**普通文件**，其他的头文件都是**链接文件**，这是 rte_config.h 的特别之处。

ls -l 查看 rte_config.h 与任意一个其它的头文件信息，输出如下：
```
[localhost include]$ ls -lh rte_eal.h
lrwxrwxrwx 1 xx xx 45 Aug  4 19:15 rte_eal.h -> ../../lib/librte_eal/common/include/rte_eal.h
[localhost include]$ ls -lh ./rte_config.h
-rw-rw-r-- 1 xx xx 11K Aug  4 15:55 ./rte_config.h
```
可以看到 rte_eal.h 是一个链接文件，指向 dpdk 源码目录中的头文件；rte_config.h 则是一个普通文件。

### rte_config.h 文件的生成过程
上文中已经提到过 rte_config.h 文件是使用 .config 文件生成的，这里分析下具体的生成过程。

dpdk 源码目录下 mk 子目录中的  rte.sdkconfig.mk Makefile 文件中描述了 rte_config.h 的生成过程。

相关的 Makefile 脚本内容如下：

```Makefile
$(RTE_OUTPUT)/include/rte_config.h: $(RTE_OUTPUT)/.config
        $(Q)rm -rf $(RTE_OUTPUT)/include $(RTE_OUTPUT)/app \
                $(RTE_OUTPUT)/hostapp $(RTE_OUTPUT)/lib \
                $(RTE_OUTPUT)/hostlib $(RTE_OUTPUT)/kmod $(RTE_OUTPUT)/build
        $(Q)mkdir -p $(RTE_OUTPUT)/include
        $(Q)$(RTE_SDK)/scripts/gen-config-h.sh $(RTE_OUTPUT)/.config \
                > $(RTE_OUTPUT)/include/rte_config.h
```
上面的格式是 Makefile 文件的写法。可以看到目标 rte_config.h 文件依赖 .config 文件来生成。
需要更新 rte_config.h 文件时，会执行如下步骤：

1. 删除 RTE_TARGET 目录中的 include app lib hostlib kmod 等中间生成的目录
2. 重新创建 RTE_TARGET include 目录
3. 调用 gen-config-h.sh 文件生成 rte_config.h，重定向会清空已经存在的 rte_config.h 文件内容

gen-config-h.sh 脚本内容如下：

```shell
#!/bin/sh
echo "#ifndef __RTE_CONFIG_H"
echo "#define __RTE_CONFIG_H"
grep CONFIG_ $1 |
grep -v '^[ \t]*#' |
sed 's,CONFIG_\(.*\)=y.*$,#undef \1\
#define \1 1,' |
sed 's,CONFIG_\(.*\)=n.*$,#undef \1,' |
sed 's,CONFIG_\(.*\)=\(.*\)$,#undef \1\
#define \1 \2,' |
sed 's,\# CONFIG_\(.*\) is not set$,#undef \1,'
echo "#endif /* __RTE_CONFIG_H */"
```
上述脚本中的 $1 就是 .config 文件的路径，这个脚本用来生成 rte_config.h 文件。

### 什么时候需要生成 rte_config.h 文件？
按照 Makefile 的规则，目标文件并不是在任何时候都会更新。只有在以下两种情况下 rte_config.h 文件会更新：

1. 目标文件不存在时
2. 目标文件存在且时间戳落后于依赖文件时

当 rte_config.h 文件不存在时，dpdk 在编译时需要首先根据 rte_config.h 文件生成，这样的逻辑没有问题。

当 rte_config.h 文件存在时，dpdk 在编译时需要检查时间戳来判断是否需要重新生成，这里就会判断 .config 文件与 rte_config.h 文件的时间戳，只有当 rte_config.h 时间戳比 .config 文件早时（落后于依赖文件时）才会重新生成。

这里就有一个潜在的问题。

### svn 库中 RTE_TARGET 目标目录中 include 目录存在 rte_config.h 的情况
上面我已经说明了 rte_config.h 文件更新的时机，在我们维护的 dpdk 版本中 RTE_TARGET 目标目录中 include 存在 rte_config，因此只有当 rte_config.h 时间戳比 .config 文件早的时候，rte_config.h 文件才会重新生成，否则它会使用 svn 库中存在的版本。

我重新拉取一个 dpdk 版本，然后查看 .config 文件与 rte_config.h 文件的时间戳，输出信息如下：

```
ls -l --full-time .config ./include/rte_config.h
-rw-rw-r-- 1 xx xx 15969 2020-08-05 11:37:11.780409454 +0800 .config
-rw-rw-r-- 1 xx xx 10695 2020-08-05 11:37:11.781409454 +0800 ./include/rte_config.h
```
可以看到 rte_config.h 的时间戳要比 .config 晚，所以在这种情况下 rte_config.h 文件不会更新。

目标目录中执行 make V=1 打印详细信息，有如下输出
```
[localhost x86_64-native-linuxapp-gcc]$ make V=1
make -f /tmp/dpdk-16.04/mk/rte.sdkconfig.mk checkconfig
make -f /tmp/dpdk-16.04/mk/rte.sdkconfig.mk \
        headerconfig NODOTCONF=1
make -s depdirs
make -f /tmp/dpdk-16.04/mk/rte.sdkbuild.mk all
== Build lib
make S=lib -f /tmp/dpdk-16.04/lib/Makefile -C /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/build/lib all
== Build lib/librte_compat
  SYMLINK-FILE include/rte_compat.h
ln -nsf `/tmp/dpdk-16.04/scripts/relpath.sh /tmp/dpdk-16.04/lib/librte_compat/rte_compat.h /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/include` /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/include
```
上述输出中没有执行生成 rte_config.h 的操作。

这时我们修改 .config 文件的内容，例如修改 MAX_ETHPORTS 为 128，相关修改如下：

```
Index: .config
===================================================================
--- .config     (revision 19876)
+++ .config     (working copy)
@@ -129,7 +129,7 @@
 # Compile generic ethernet library
 CONFIG_RTE_LIBRTE_ETHER=y
 CONFIG_RTE_LIBRTE_ETHDEV_DEBUG=n
-CONFIG_RTE_MAX_ETHPORTS=64
+CONFIG_RTE_MAX_ETHPORTS=128
 CONFIG_RTE_MAX_QUEUES_PER_PORT=1024
 CONFIG_RTE_LIBRTE_IEEE1588=n
 CONFIG_RTE_ETHDEV_QUEUE_STAT_CNTRS=16
 ```
 修改完成后，重新执行 make V=1 有如下输出：
```
make -f /tmp/dpdk-16.04/mk/rte.sdkconfig.mk checkconfig
make -f /tmp/dpdk-16.04/mk/rte.sdkconfig.mk \
        headerconfig NODOTCONF=1
rm -rf /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/include /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/app \
        /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/hostapp /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/lib \
        /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/hostlib /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/kmod /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/build
mkdir -p /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/include
/tmp/dpdk-16.04/scripts/gen-config-h.sh /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/.config \
        > /tmp/dpdk-16.04/x86_64-native-linuxapp-gcc/include/rte_config.h
```
可以看到这次 rte_config.h 文件确实更新了。

## 需要提交 rte_config.h 文件的修改吗？
上面的操作是没有问题的，在这个基础上进行 release 也是没有问题的。

**但是我们在提交对 .config 文件的修改时，很少有人会同步修改 svn 中的 rte_config.h 文件，这样就存在了一个隐患。**

当其他人**重新拉取 dpdk svn 编译时**，由于 svn 中**存在 rte_config.h 且 rte_config.h 文件的时间戳比 .config 文件晚**，这次编译将**不会重新成 rte_config.h 文件**，这样**一直使用的就是 svn 库中存在的 rte_config.h 文件**，这就可能**造成问题**。

## 最终的解决方案
同步修改 svn 库中的 rte_config.h 文件能够避免这个问题，但是不是很好的解决方案。

实际上，我们不应该在 svn 的源码路径中管理这些编译过程中会**自动生成的文件**，这样一方面可能**干扰到正常的编译过程**，另一方面也可能在我们提交修改时出现遗漏从而埋下一个隐患。

故而针对这个问题，选择直接删除 dpdk svn 库中的 include 目录即可，这样每次 rte_config.h 文件都能根据 .config 文件来更新，不会产生 .config 文件不生效的问题。





