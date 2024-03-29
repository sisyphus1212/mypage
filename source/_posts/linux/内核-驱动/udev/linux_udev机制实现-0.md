---
title: linux_udev机制实现-0
date: 2022-09-20 16:04:03
index_img: https://github.com/sisyphus1212/images/blob/main/mk-2022-09-20-23-08-10.png?raw=true
categories:
  - [linux,网络开发, 驱动, udev]
tags:
 - netlink
 - linux驱动
 - kernel
---
## udev 简介

在早期的 linux 中,对于设备管理的策略是比较简单的,各个硬件设备对应 /dev 目录下的一些静态属性文件,这时候的硬件环境并不复杂,外围硬件通常比较少,更没有热插拔的需求.

不过,随着这几十年硬件的爆发式增长以及移动设备的兴起,设备管理开始变得复杂起来,一方面是外围设备的增多,设备的复杂度逐渐提高,另一方面,系统需要满足越来越多的"动态需求",也就是一些即插即用的设备,比如:USB 网卡,硬盘等.

为了应对外部环境的变化,linux 首先推出了 devfs,首次出现在 2.3 内核中,它主要特点是支持设备的热插拔,但是 devfs 不支持持久化的命名、后期维护不积极，同时考虑到设备管理的工作没必要完全放在内核中等因素，在不久之后的 2.6 版本内核中就被新的设备管理策略 udev 所替代,一直沿用至今.

值得一提的是,udev 是一个用户空间程序,通过 netlink 机制与内核进行交互,监听内核的设备更改并相应地修正应用空间的设备接口.

udev 分为两个部分,一个是守护进程 udevd,另一部分是客户端程序,主要是 udevadm,提供用户层面的操作接口.在早期 udev 作为独立的服务运行在 Linux 系统中,后来被并入 systemd 管理系统中,这种迁移并不对 udev 的功能造成任何影响.

## udev 能做什么?

设备管理是一个抽象的概念,设备本身也囊括了非常多的东西,linux 中的设备分为三种:字符设备，块设备和网络设备,对于 Linux 来说,设备在硬件上通过各种总线连接到系统中,然后在软件层面导出操作设备的接口,几乎所有设备都是这种方式运行在 linux 中(网络设备稍微特殊一些,它不会在通用的/dev,/sys目录下直接导出操作接口).

不同设备的区别在于:硬件上,有些设备可能是通过 USB 总线连接到机器,而有些是通过串口或者网口.软件上,某些设备对应单一的操作接口,而某些设备的设备接口更加复杂.

需要注意的是,udev 是一个用户空间的程序,所以可以想到,硬件相关的操作是和 udev 完全无关的,因为 linux 中只有内核才有操作硬件资源的权限,所以内核负责处理设备连接到系统,包括总线的匹配,连接,底层通信等工作.

而 udev 负责以下的用户空间工作:

* 重新为设备节点命名
* 通过创建链接的方式针对同一个设备提供一个持久化的命名
* 根据程序输出为设备节点命名
* 设置设备节点的权限
* 当设备修改的时候,执行指定的脚本程序
* 为网络接口重新命名,网络设备

在 linux 下，一切皆文件，上文中所说的软件接口也正是以文件的形式导出，所以 udev 的工作也是和设备文件接口打交道，包括命名、权限等,当然,这依赖于内核提供的设备信息.

## udev 是如何实现设备管理的？

设备管理中大部分的工作都是围绕设备接口相关，最多的自然是设备的创建，，下面我们就以系统中的实时时钟(RTC)为例，看看一个硬件设备从连接到用户接口的导出是怎么样的一个过程。

* RTC 是低速设备，通常使用 i2c 接口与 CPU 连接，如果需要将一个 i2c 接口的 RTC 在 linux 中使用，第一步自然是硬件连接，通常是四根线：VCC(电源)、GND(地)、SCK(时钟线)、SDA(信号线)。
* 第二步是将该设备注册到内核中，在新版的内核中通过设备树来描述该 RTC 设备，设备树节点中包含该 RTC 设备的相关信息，而老版本内核中需要编写相应的设备节点并注册到内核中。
* 内核在启动并初始化对应的 i2c 总线时，会根据设备树节点中的 "compatible" 属性，匹配到该 RTC 对应的驱动程序，并执行驱动程序中的 probe 函数。
* 在 probe 函数中，会为该设备节点创建一系列的设备节点，包括 /proc,/sys 等目录下的文件节点，同时还会直接或者间接地调用到 kobj_uevent_env() 函数，这个函数就会通过 netlink 通信机制向用户空间广播设备创建的相关信息，这类通知信息的格式通常为：ACTION=add DEVPATH=/module/kset_create_del SUBSYSTEM=module SEQNUM=3676，这些信息中会包含操作类型(add)，文件接口的路径，子系统的名称等以方便用户空间识别目前对应的是哪一个设备.同时,内核还会将一部分设备信息通过 sysfs 文件系统导出到 /sys 目录下,udev 同样会读取 /sys 目录下的设备信息.
* udevd 守护进程通过监听内核对应的 netlink 套接字，读取到内核广播的设备信息。
* 在读取到内核创建的对应的 RTC 设备信息之后,udevd 守护进程并不会自行分析内核信息中的每个字段，而是将设备信息与一种名为 .rule 为后缀的规则文件进行匹配，这些 rules 文件是系统管理员预定义的专门针对设备信息的解析文件，它会告诉 udevd 接收到内核设备信息时该如何操作。
* 当存在某个 rules 文件中的规则与内核设备信息相匹配时，就会执行相应的操作，而这个操作也正是规则文件中定义的，比如对于 RTC 而言， /lib/udev/rules.d/50-udev-default.rules 中的下列两行规则就会匹配成功：
  SUBSYSTEM=="rtc", ATTR{hctosys}=="1", SYMLINK+="rtc"
  SUBSYSTEM=="rtc", KERNEL=="rtc0", SYMLINK+="rtc", OPTIONS+="link_priority=-100"
  其中， == 表示匹配的规则，比如 SUBSYSTEM 必须为 rtc 才能匹配到这两条规则，+= 表示要执行的动作，这里表示在 /dev 目录下创建 rtc 软链接，而 /dev/rtc0 文件接口则由内核直接创建。

这是一个相对简单的示例，展示了一个设备从硬件的连接到内核总线的处理再到用户接口的导出整个过程，而设备的变动通常被称为设备事件，设备事件由内核传递到应用空间，再由应用空间的 udevd 处理。

## rules 规则文件

对于系统管理员来说,udev 最核心的部分在于 .rules 规则文件,设备的插拔与修改信息由内核传递到用户空间,而用户空间将会做出怎样的操作几乎完全取决于规则文件中预定义的行为(udevd存在一些內建函数和默认操作),因此,如果要掌握 udev 的使用,掌握规则文件是第一步,辛运的是,这并不难.

规则文件被放置在系统目录中,且必须以 .rules 为后缀,对应的系统目录有:/run/udev/rule.d,/etc/udev/rules.d,/lib/udev/rules.d. 其中,系统软件在安装时通常会把规则文件放在 /lib/udev/rules.d 目录下,而 /run,/etc 下的 rules.d/ 目录下的规则文件则用于系统管理员的本地配置.
(**注:在我的嵌入式设备和 ubuntu18 上，发现 /run/udev/rules.d 并不存在，如果手动地创建了对应的目录，udev才会去读取该目录下的文件。**)

当系统中存在同名不同目录的规则文件时,/etc 下的优先级最高,/run 次之,/lib 优先级最低,高优先级的同名文件将会覆盖低优先级文件.如果要屏蔽一个规则文件，直接在 /etc 下创建该文件的一个软链接，指向 /dev/null 是不错的方法。

同时,对于不同名的规则文件,其优先级的管理不是由存放目录来决定的,而是通过文件名来实现的,规则文件命名通常是以数字开头,比如 50-udev-default.rules,通过判断规则文件命名的前导数字来确定规则文件被解析的优先级.

以数字开头并不是硬性规定,这是一种约定俗成的规则,如果某个调皮的用户不使用数字开头,udev 同样会以字母顺序进行排序,只是看起来这种方式不直观,不建议这么做.

### udev 总体解析规则

udev 在解析所有规则文件时,遵循以下的规则:

* 所有的规则都运行在一个解析空间中,尽管这些规则被划分到多个文件,多个目录下,它们只有解析的先后顺序差别,而没有区域的差别,因此,你可以简单地理解为:所有的规则文件中定义的规则相当于存在于一个大文件中,理论上来说,在每一次匹配中所有规则都会被检查到,实际上考虑到效率因素,规则文件中支持逻辑语句进行过滤,比如 goto.使用调试工具 udevadm test 命令可以在终端看到规则文件的解析过程。
* 规则文件中支持 goto 语句和 label 相结合实现规则的过滤.
* 尽管 goto 语句支持跳转到不同文件下的 label,但是建议不要这么做,这可能造成一些混乱
* 使用 goto 时不要回跳,这可能导致死循环
* 在规则文件中可以使用全局变量,全局变量可以应用在全局的文件解析过程中.

### 规则文件的编写规则

规则文件是由多条规则以及少量的逻辑控制语句组成,规则文件内容的编写也应该遵循相应的规则:

* 单条规则必须定义在一行内,可以通过 \ 进行换行.
* 规则中包含匹配部分(match)和执行动作(action)部分
* 规则中的语法由三部分组成:键,操作符,值,比如:ACTION=="remove",其中 ACTION 为键, == 为操作符,而 "remove" 为值.
* match 部分通过 == 或者 != 进行匹配,通常是字符串匹配,比如:BUS=="usb",在内核传递到用户空间的 netlink 信息中可能包含 USB 关键字,通过该关键字进行匹配.
* action 部分通过 = 进行赋值,也可以通过 += 附加,比如 NAME="mydev",将设备命名为 mydev.
* 因为 udev 会通过 /sys 目录下给出的设备信息创建设备节点,所以 match 部分也支持通过判断 /sys 下的文件进行匹配.
* 当 match 部分匹配时,action 部分指定的命令将会被执行,可能是创建文件节点,创建链接,或者新增环境变量.
* 所有规则文件都会被触发,除了同名的规则文件会被覆盖.
* 如果存在两条相同的规则,较早解析的规则条目优先级更高,后续相同的规则条目将不会有效,所以如果你的规则比较重要,或者需要刻意地覆盖系统的规则,将你的规则文件以小数字命名即可.
* action 中的 += 表示附加,比如 symlink+=foo,表示在前一个操作完成之后,再创建 foo 的软链接.

## udevd 守护进程

在系统启动阶段，udev 会启动其守护进程 udevd，udevd 是 udev 的核心部分，执行了 udev 的大部分功能，包括监听并处理内核设备事件、给客户端提供调试和操作接口、维护设备事件的数据库等等。

在上文中提到，udev 被集成到了 systemd 中，默认情况下，其对应的服务文件为：

* /lib/systemd/system/udev.service：主要的服务单元文件，该文件会设置开机阶段启动，服务单元执行的主体进程为：/lib/systemd/systemd-udevd，systemd-udevd 也就是 udevd 的可执行文件。
* systemd-udevd-control.socket：socket 文件，因为对于 systemd 来说，建议所有启动进程将套接字独立出来，这样 systemd 就可以在启动阶段一次性将所有套接字启动，以提高启动速度。该套接字主要负责客户端与 udevd 的通信。
* systemd-udevd-kernel.socket：该套接字负责 udevd 与内核之间的 netlink 通信。
* systemd-udev-settle.service：udev 的客户端程序
* systemd-udev-trigger.service：udev 的客户端程序

### 进程选项

udevd 守护进程的执行支持多个命令行选项，可以通过将命令行选项添加到 /lib/systemd/system/udev.service 文件中 ExecStart=/lib/systemd/systemd-udevd 语句后面来为 udevd 守护进程提供命令行选项。

* -d，daemon：脱离控制台，并作为后台守护进程运行
* -D，--debug：在标准错误上输出更多的调试信息
* -c=，--children-max=：限制最多同时并行处理多少个设备事件
* -e=，--exec-delay：在运行 RUN 前暂停的秒数。 可用于调试处理冷插事件时， 加载异常内核模块 导致的系统崩溃。
* -t=, --event-timeout=：设置处理设备事件的最大允许秒数， 若超时则强制终止此设备事件。默认值是180秒。
* -N=, --resolve-names=：指定 systemd-udevd 应该何时解析用户与组的名称： early(默认值) 表示在规则的解析阶段； late 表示在每个设备事件发生的时候； never 表示从不解析， 所有设备的属主与属组都是 root
* -h, --help：显示简短的帮助信息并退出。
* --version：显示简短的版本信息并退出。

### 配置文件

除了提供程序执行时的命令行选项,另一种配置 udevd 的方式就是配置文件,配置文件为 /etc/udev/udev.conf.该文件包含一组 允许用户修改的变量( VAR=VALUE 格式)，以控制该进程的行为。 空行或以"#"开头的行将被忽略。 可以设置的变量(VAR)如下:

* udev_log=:指定日志等级.
* children_max=:表示运行同时处理设备事件的最大数量,等价于 --children-max= 选项。
* exec_delay=:正正式,表示延迟多少秒之后再执行 RUN= 中指定的指令. 等价于 --exec-delay= 选项。
* event_timeout=:正整数,表示等待设备事件完成的超时秒数,如果超时,设备事件会被强制终止,默认为 180 秒.等价于 --event-timeout= 选项。
* resolve_names=:设置 systemd-udevd 在何时解析用户与组的名称。 默认值 early 表示在规则的解析阶段； late 表示在每个设备事件发生的时候； never 表示不解析(所有设备都归 root 用户拥有)。等价于 --resolve-names= 选项。

相对于指定命令行参数而言,推荐使用修改配置文件来更改守护进程行为.

在后续的文章中,将会继续介绍规则文件的编写,以及 udev 的使用.

参考:http://www.jinbuguo.com/systemd/systemd-udevd.service.html
参考:http://www.jinbuguo.com/systemd/udev.conf.html
