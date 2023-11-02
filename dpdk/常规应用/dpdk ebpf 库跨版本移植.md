# dpdk ebpf 库跨版本移植

## 目标

dpdk-19.11 ebpf 库移植到 dpdk-16.04 中并适配 testpmd 来测试。

## 移植前评估工作

评估方法：

1. 使用 dpdk-19.11 编译生成 librte_bpf.a
2. nm 查看 .a 中的符号
3. 过滤出 U 类型的符号并排除内部符号

评估的情况：

[libelf.so](http://libelf.so/) 提供的符号：

```c
elf64_getehdr
elf64_getshdr
elf_begin
elf_end
elf_errmsg
elf_errno
elf_getdata
elf_getscn
elf_ndxscn
elf_nextscn
elf_strptr
elf_version
```

dpdk 需要支持的接口：

```c
rte_eth_add_rx_callback
rte_eth_add_tx_callback
rte_eth_dev_is_valid_port
rte_eth_remove_rx_callback
rte_eth_remove_tx_callback
rte_log
rte_log_register
rte_log_set_level
rte_mempool_ops_table
```
dpdk-16.04 已经具备的符号：

```c
rte_eth_add_rx_callback
rte_eth_add_tx_callback
rte_eth_dev_is_valid_port
rte_eth_remove_rx_callback
rte_eth_remove_tx_callback
rte_log
```
经过确认需要适配的符号如下：
```c
rte_log_register
rte_mempool_ops_table
rte_log_set_level
```

根据上述信息，评估适配的工作量很少，风险可控。

## 移植的注意事项

 ### 1. librte_bpf Makefile 文件中设置 DEPDIRS 变量，将依赖的项目列举出来

   依赖 lib/librte_net lib/librte_eal lib/librte_mbuf  lib/librte_ether 这几个项目
    
### 2. dpdk-16.04 不支持 rte_log_register 函数

 dpdk 高版本使用 rte_log_register 来注册一种类型的 log 事件，dpdk-16.04 的 log 系统比较落后，这部分逻辑需要去掉，同时 RTE_BPF_LOG 宏定义也需要修改。
    
 可以在 **rte_log.h** 中添加一个 **RTE_LOGTYPE_BPF** 的宏定义并修改 **RTE_BPF_LOG** 的实现。

 ### 3. dpdk-16.04 中用于标识网卡 id 的 port_id 为 uint8_t 类型，高版本为 uint16_t 类型
 可以写一行 sed 命令一键替换
### 4. __rte_experimental 与 __rte_always_inline 这两个宏在 dpdk-16.04 中缺少
__rte_always_inline 的定义可以从高版本 **copy** 过来，__rte_experimental  也可以从高版本 copy 过来，最好是加条件编译控制定义为空
### 5. mk/rte.app.mk 中添加 rte_bpf 的链接项目与 -lelf 的条件控制链接项目
   示例如下：
    
  ```c
    +_LDLIBS-$(CONFIG_RTE_LIBRTE_BPF)            += -lrte_bpf
    
    +ifeq ($(CONFIG_RTE_LIBRTE_BPF_ELF),y)
    +_LDLIBS-$(CONFIG_RTE_LIBRTE_BPF)            += -lelf
    +endif
  ```

### 6. 修改 config 目录中的默认 dpdk 编译配置文件，增加 CONFIG_RTE_LIBRTE_BPF 与 CONFIG_RTE_LIBRTE_BPF_ELF 的配置项目，并更新 RTE_TARGET 目录中的 .config 文件
## 7. 移植 bpf_cmd.c 与 bpf_cmd.h 到 testpmd 中时，需要根据调整 bpf_cmd.c 文件包含的头文件
### 8. bpf arm64 jit 代码翻译相关源码需要依赖两个高版本的宏，在 rte_common.h 中添加 rte_fls_u64 与 RTE_ALIGN_MUL_CEIL 宏定义即可

## 移植后测试
在虚拟机中使用 testpmd 测试移植的 bpf 库。

bpf-load 加载：

```c
testpmd> bpf-load  rx 0 0 J ./dummy.o
validate(0x7ffd0c107740) stats:
nb_nodes=2;
nb_jcc_nodes=0;
node_color={[WHITE]=0, [GREY]=0,, [BLACK]=2};
edge_type={[UNKNOWN]=0, [TREE]=1, [BACK]=0, [CROSS]=0};
rte_bpf_elf_load(fname="./dummy.o", sname=".text") successfully creates 0x7f141b176000(jit={.func=0x7f141b14c000,.sz=8});
0:Success
```
dummy.o bpf 指令码成功加载。

perf 观测函数调用：

```c
  52.96%  testpmd   [.] bpf_rx_callback_jit
  30.99%  testpmd   [.] pkt_burst_io_forward
  15.02%  testpmd   [.] eth_em_recv_pkts
   0.95%  testpmd   [.] start_pkt_forward_on_core
```

bpf_rx_callback_jit 函数正常调用，移植成功。
