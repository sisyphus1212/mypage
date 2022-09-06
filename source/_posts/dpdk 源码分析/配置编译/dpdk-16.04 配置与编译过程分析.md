# dpdk-16.04 配置与编译过程分析
## dpdk .config 文件的生成过程
dpdk 有内部的 .config 文件，编译前需要先创建不同架构 .config 配置文件与 build 目录。

dpdk 源码目录 config 子目录存放用于生成 .config 文件的源文件，目录内容如下：

```c
common_base                            defconfig_i686-native-linuxapp-gcc     defconfig_x86_64-native-bsdapp-gcc
common_bsdapp                          defconfig_i686-native-linuxapp-icc     defconfig_x86_64-native-linuxapp-clang
common_linuxapp                        defconfig_ppc_64-power8-linuxapp-gcc   defconfig_x86_64-native-linuxapp-gcc
defconfig_arm64-armv8a-linuxapp-gcc    defconfig_tile-tilegx-linuxapp-gcc     defconfig_x86_64-native-linuxapp-icc
defconfig_arm64-thunderx-linuxapp-gcc  defconfig_x86_64-ivshmem-linuxapp-gcc  defconfig_x86_x32-native-linuxapp-gcc
defconfig_arm64-xgene1-linuxapp-gcc    defconfig_x86_64-ivshmem-linuxapp-icc
defconfig_arm-armv7a-linuxapp-gcc      defconfig_x86_64-native-bsdapp-clang
```

common_base 文件为基本配置，common_bsdapp 与 common_linuxapp 代表 dpdk 支持的两种大的系统：

1. bsd 系统
2. linux 系统

**defconfig_xx 配置选项配置编译架构，工具链名称，defconfig_xx 包含 common_bsdapp、common_lnuxapp 的配置项目，common_bsdapp、common_linuxapp 包含 common_base 的配置项目。**


以 x86_64-native-linuxapp-gcc 为例，要生成 x86_64-native-linuxapp-gcc 的配置文件，可以在 dpdk 源码跟目录中执行如下命令：

```bash
make config O=./x86_64-native-linuxapp-gcc T=x86_64-native-linuxapp-gcc
```

执行成功后会生成 x86_64-native-linuxapp-gcc 目录，此目录的内容如下：

```bash
.  ..  build  .config  .config.orig  .depdirs  include  Makefile
```

1. bulid 为编译过程中中间文件保存目录
2. .config 文件是生成的配置文件内容，.config.orig 是配置文件的备份
3. include 目录中为生成的 rte_config.h 文件
4. .depdirs 中为不同模块的依赖关系
5. Makfile 为构建使用的编译脚本


.config 文件通过指定 -x assembler-with-cpp 参数调用 cc（gcc） 来生成，示例命令如下：

```bash
 cc -E -undef -P -x assembler-with-cpp -ffreestanding -o /home/longyu/dpdk-16.04/.config /home/longyu/dpdk-16.04/config/defconfig_x86_64-native-linuxapp-gcc
```

## dpdk rte_config 文件的生成过程

.config 文件维护了 dpdk 内部组件的配置，实际编译中会根据 .config 内容来生成 rte_config.h 文件，实际的配置通过头文件中的宏定义值达成。

**rte_config.h 头文件通过调用 scripts/gen-config.h.sh 来生成，此脚本的输出信息被重定向为 rte_config.h，脚本内容为几个 echo 与 sed 替换命令。**

需要说明的是，当 .config 文件更新后，重新生成 rte_config.h 之前会编译生成的中间文件目录。

.config 与 rte_config.h 文件的生成过程由 mk/rte.sdkconfig.mk 文件控制，可以阅读这个文件获取更详细的信息。

## dpdk 完整构建过程

1.构建 mk/rte.sdkconfig.mk 中的 checkconfig 目标，检查是否需要重新生成配置文件

2.构建 mk/rte.sdkconfig.mk 中的 headerconfig 目标，生成 rte_config.h 

3.构建 depdirs 目标，在编译目标目录中生成 .depdirs 文件

4.构建 mk/rte.sdkbuild.mk all 配置，rte.sdkbuild 中首先包含 .depdirs 文件，根据依赖关系确定编译的优先级顺序

5.在编译前，首先包含 mk/rte.vars.mk 文件，此文件进而包含 mk/target/generic/rte.vars.mk，mk/target/generic/rte.vars.mk 进而包含 toolchain/$(RTE_TOOLCHAIN)/rte.vars.mk 下面的头文件配置编译工具链，dpdk 中工具链前缀通过 CROSS 变量控制。

6.根据 Makefile 在 build 目录中生成 .xxx.o.d、.xxx.o.cmd 文件，创建 Makefile 中声明的 SYMLINK 头文件，执行编译过程，编译完成后执行 install 安装目标文件

dpdk 构建系统有几个不同的类别，如 lib、module、app、extlib、extapp 等等几个对象类别，lib 是一个常见的类别，其源码主要过程如下：

1. 包含 mk/internal/rte.xx-pre.mk 文件，执行编译前的设定
2. 针对 lib 类别编译目标自身的设定
3. 包含 mk/intermal/rte.xx-post.mk 文件，执行编译后的设定

其它的类别对象的构建过程大同小异，不展开说明！

dpdk 的构建过程比较灵活，支持单独编译每一种目标类型！要添加自己的编译参数，可以设定 EXTRA_CFLAGS 变量。