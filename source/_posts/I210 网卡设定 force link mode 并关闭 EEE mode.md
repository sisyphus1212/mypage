# I210 网卡设定 force link mode 并关闭 EEE mode
## 前言
在定位 I210 网卡接口震荡问题的时候，阅读手册发现网卡支持设定 force mode，理解为可以将网卡设定为强制 up 状态，同时怀疑 eee 节能模式导致网卡休眠从而发生接口 down 的问题，于是需要设定 force mode 为 up 的时候同时关闭 eee 节能模式，需要修改 dpdk-16.04 中的部分代码来进行测试。

## I210 手册中的相关内容
I210 手册 P107 页描述了设定 force mode 需要设定的寄存器内容信息摘录如下：

```
 Move to Force mode by setting the following bits:
— CTRL.FD (CSR 0x0 bit 0) = 1b
— CTRL.SLU (CSR 0x0 bit 6) = 1b
— CTRL.RFCE (CSR 0x0 bit 27) = 0b
— CTRL.TFCE (CSR 0x0 bit 28) = 0b
— PCS_LCTL.FORCE_LINK (CSR 0X4208 bit 5) = 1b
— PCS_LCTL.FSD (CSR 0x4208 bit 4) = 1b
— PCS_LCTL.FDV (CSR 0x4208 bit 3) = 1b
— PCS_LCTL.FLV (CSR 0x4208 bit 0) = 1b
— PCS_LCTL.AN_ENABLE (CSR 0x4208 bit 16) = 0b
```

dpdk-16.04 中 pmd 与 kni 内核驱动同时使用，需要确定设定真实生效，这一点通过查看寄存器内容来确认。

## igb pmd 驱动 igb_ethdev.c 的修改
通过修改初始化逻辑来完成，patch 如下：
```c
Index: drivers/net/e1000/igb_ethdev.c
===================================================================
--- drivers/net/e1000/igb_ethdev.c
+++ drivers/net/e1000/igb_ethdev.c
@@ -1390,7 +1390,28 @@
        }

        e1000_setup_link(hw);
+
+    uint32_t ipcnfg, eeer;

+    ipcnfg &= ~(E1000_IPCNFG_EEE_1G_AN | E1000_IPCNFG_EEE_100M_AN);
+    eeer &= ~(E1000_EEER_TX_LPI_EN | E1000_EEER_RX_LPI_EN |
+                  E1000_EEER_LPI_FC);
+
+    E1000_WRITE_REG(hw, E1000_IPCNFG, ipcnfg);
+    E1000_WRITE_REG(hw, E1000_EEER, eeer);
+
+    uint32_t pcs_lctl;
+    pcs_lctl = E1000_READ_REG(hw, E1000_PCS_LCTL);
+    printf("current PCS_LCTL is %u\n", pcs_lctl);
+
+    /* disable AN_ENABLE */
+    pcs_lctl &= ~(E1000_PCS_LCTL_AN_ENABLE);
+
+    /* enable FORCE_LINK and  FORCE_LINK_UP */
+    pcs_lctl |= E1000_PCS_LCTL_FORCE_LINK | E1000_PCS_LCTL_FLV_LINK_UP | E1000_PCS_LCTL_FSD;
+    E1000_WRITE_REG(hw, E1000_PCS_LCTL, pcs_lctl);
+     printf("after changed PCS_LCTL is %u\n", E1000_READ_REG(hw, E1000_PCS_LCTL));
+
        if (rte_intr_allow_others(intr_handle)) {
                /* check if lsc interrupt is enabled */
                if (dev->data->dev_conf.intr_conf.lsc != 0)
 ```

## kni 驱动 e1000_82575.c 代码的修改
同样通过修改初始化代码来完成，patch 如下：
```c
Index: lib/librte_eal/linuxapp/kni/ethtool/igb/e1000_82575.c
===================================================================
--- lib/librte_eal/linuxapp/kni/ethtool/igb/e1000_82575.c
+++ lib/librte_eal/linuxapp/kni/ethtool/igb/e1000_82575.c
@@ -2802,6 +2802,7 @@
        ipcnfg = E1000_READ_REG(hw, E1000_IPCNFG);
        eeer = E1000_READ_REG(hw, E1000_EEER);

+#if 0
        /* enable or disable per user setting */
        if (!(hw->dev_spec._82575.eee_disable)) {
                u32 eee_su = E1000_READ_REG(hw, E1000_EEE_SU);
@@ -2818,10 +2819,17 @@
                eeer &= ~(E1000_EEER_TX_LPI_EN | E1000_EEER_RX_LPI_EN |
                          E1000_EEER_LPI_FC);
        }
+#endif
+
+    　　ipcnfg &=  ~(E1000_IPCNFG_EEE_1G_AN | E1000_IPCNFG_EEE_100M_AN);
+    　　eeer &= ~(E1000_EEER_TX_LPI_EN | E1000_EEER_RX_LPI_EN |
+                   E1000_EEER_LPI_FC);
+
        E1000_WRITE_REG(hw, E1000_IPCNFG, ipcnfg);
        E1000_WRITE_REG(hw, E1000_EEER, eeer);
-       E1000_READ_REG(hw, E1000_IPCNFG);
-       E1000_READ_REG(hw, E1000_EEER);
+
+    printk("after set ipcnfg is %x, eeer is %x\n", E1000_READ_REG(hw, E1000_IPCNFG), E1000_READ_REG(hw, E1000_EEER));
+
```
测试发现 kni 中默认是开启 eee 模式的，注释掉了开启 eee 模式的代码，并清除相关寄存器的设定，重新设定后使用 printk 打印寄存器内容，确定修改生效。

## igb_ethtool.c 的修改
为了在程序执行后进一步确认 force link mode 设定成功，且 EEE mode 正常关闭，在 igb 网卡获取寄存器的函数中添加打印，打印出 ipcnfg 与 eeer 寄存器的内容。

```c
Index: lib/librte_eal/linuxapp/kni/ethtool/igb/igb_ethtool.c
===================================================================
--- lib/librte_eal/linuxapp/kni/ethtool/igb/igb_ethtool.c
+++ lib/librte_eal/linuxapp/kni/ethtool/igb/igb_ethtool.c
@@ -495,6 +495,8 @@
        memset(p, 0, IGB_REGS_LEN * sizeof(u32));

        regs->version = (1 << 24) | (hw->revision_id << 16) | hw->device_id;
+
+    	printk("ipcnfg is %x, eeer is %x\n", E1000_READ_REG(hw, E1000_IPCNFG), E1000_READ_REG(hw, E1000_EEER));

        /* General Registers */
        regs_buff[0] = E1000_READ_REG(hw, E1000_CTRL);
```

程序运行后，通过执行 ethtool -d 查看 **PCS_LCTL 寄存器与 dmesg 的输出来确认设置生效**。

## 测试结果
测试发现 force link mode up 并不像我们想象的能够让网卡一直处于 up 状态，拔了网线后仍旧能够变为 down，推测强制的定义应该针对的是速率与双工模式。


