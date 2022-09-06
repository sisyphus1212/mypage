# dpdk-16.04 eal lcore 多线程机制分析
# dpdk 多线程流水线
dpdk 抽象的 eal 环境在初始化的时候会探测系统上可用的 cpu 核，为每个核创建一个线程，并初始化相应的数据结构。

一般来说，多线程创建的时候传入的 start_routine 函数指针就限定了多线程程序执行的入口，并且当程序调用 pthread_create 成功后线程就开始执行。

对于 dpdk 来说在初始化 eal 环境时，**并不确定针对每个核创建的线程将要执行哪些任务**，这些任务的确定**推迟到 dpdk 程序编码中**，这是 dpdk 不同于常见多线程处理模型的特点。

为此，dpdk 提供接口让 dpdk 程序将需要执行的任务分发到 dpdk 内部为每个逻辑核创建的线程上，可以称为 dpdk 多线程流水线机制。

分发任务后又引入了新的问题，即这些分发的任务什么时候执行？其执行终止的状态该如何控制等等，这些都是 dpdk 多线程流水线机制需要解决的问题。

本文将从以上问题开始探讨，基于 dpdk-16.04 的 linuxapp 实现，逐步分析 dpdk 多线程流水线机制的工作原理。

# 如何动态的分发任务到多线程中？
上文已经提及，使用 pthread_create 创建的线程，一经创建成功便从 pthread_create 函数的 start_routine 参数指定的函数处开始执行。dpdk 为每个逻辑核创建的线程都指定了一个**统一的入口**，即 **eal_thread_loop** 函数，此函数负责执行下发到每个逻辑核线程的函数。

dpdk 程序下发的函数可以看做是针对逻辑核线程的配置，那这个配置在 dpdk 中有怎样的形式呢？

## lcore_config 结构
dpdk 内部抽象出的 lcore_config 结构定义了每个逻辑核线程的配置及一些私有的变量，其定义如下：

```c
/**
 * Structure storing internal configuration (per-lcore)
 */
struct lcore_config {
	unsigned detected;         /**< true if lcore was detected */
	pthread_t thread_id;       /**< pthread identifier */
	int pipe_master2slave[2];  /**< communication pipe with master */
	int pipe_slave2master[2];  /**< communication pipe with master */
	lcore_function_t * volatile f;         /**< function to call */
	void * volatile arg;       /**< argument of function */
	volatile int ret;          /**< return value of function */
	volatile enum rte_lcore_state_t state; /**< lcore state */
	unsigned socket_id;        /**< physical socket id for this lcore */
	unsigned core_id;          /**< core number on socket for this lcore */
	int core_index;            /**< relative index, starting from 0 */
	rte_cpuset_t cpuset;       /**< cpu set which the lcore affinity to */
};
```
这些数据结构可以分为如下几类：

1. 标识绑定到的线程的成员
2. 用于控制、描述 lcore 线程执行状态的成员
3. 代表分发到 lcore 线程中的执行单元的成员
4. 用于描述 cpu 亲和性及 numa 节点的成员

上述不同类别的成员一起抽象出了 dpdk 下发到每个 lcore 线程的配置，**dpdk 内部维护了一个 lcore_config 结构体数组，每个使能的逻辑核都会占据这个数组中的一项。**

下面我针对 lcore_config 结构的几个类别的成员进行分析。

### lcore_config 中标识绑定到的线程的成员
```c
	unsigned detected;         /**< true if lcore was detected */
	pthread_t thread_id;       /**< pthread identifier */
```
detected 标志这个 lcore 是否可用，thread_id 代表绑定到当前 lcore_config 上的线程 id。

thread_id 不足为奇，dpdk 在创建需要的逻辑核线程时为 thread_id 赋值，但**为何要创建一个 detected 成员呢**？

由于 dpdk 程序在运行前**并不确定系统上的逻辑核数目**，但是它内部实现为需要提前分配每个逻辑核的 lcore_config 结构的方式，而分配多少个逻辑核的 lcore_config 就成为了一个必须的参数，为此 dpdk 预设了一个参数，**默认支持 128 个逻辑核，同时这项配置也导出到 .config 中让用户动态配置**。

这样当 dpdk 程序运行时，需要根据运行环境的实际逻辑核来设定特定的 lcore_config 结构，这就需要标识出哪些 lcore_config 结构是可用的，这就是 detected 成员的功能。

dpdk 通过在 rte_eal_init 函数中调用 rte_eal_cpu_init 函数来初始化预设的每个 lcore_config 结构中的 detected 字段，此外 cpuset、 core_id 、 socket_id 也都在这个函数中被设定。

### 用于控制、描述 lcore 线程执行状态的成员
dpdk 需要分发执行单元到 lcore 线程中，这就涉及到与每个 lcore 线程的交互，需要控制执行单元执行的时机，并能够通过某个内部成员表示出每个 lcore 线程的当前状态。

如上功能对应 lcore_config 中的如下成员：

```c
	int pipe_master2slave[2];  /**< communication pipe with master */
	int pipe_slave2master[2];  /**< communication pipe with master */
	volatile enum rte_lcore_state_t state; /**< lcore state */
```
pipe_master2slave 与 pipe_slave2master 建立起了主线程与每个 lcore 逻辑线程之间的通信管道。

**为什么要创建两个匿名管道呢？**

pipe 是半双工的进程间通信方式，它的工作原理如下：
![在这里插入图片描述](https://img-blog.csdnimg.cn/20210506214520105.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L0xvbmd5dV93bHo=,size_16,color_FFFFFF,t_70)
一般来说，pipe 的一端负责读，一端负责写，数据的流动是单向的。dpdk 为了实现 master 线程与 slave 线程之间的**双向通信**就为每个 lcore 线程创建了**两个**匿名管道。

state 变量表示 lcore 线程的状态，有如下几种类型：

1. WAIT 状态，等待下发任务
2. RUNNING 状态，正在执行下发的任务
3. FINISHED 状态，下发任务执行完成

rte_eal_init 创建每个逻辑核线程时，将 state 设置为 WAIT 状态，表示线程等待任务下发。

rte_eal_init 中的相关代码如下：

```c
	RTE_LCORE_FOREACH_SLAVE(i) {

		/*
		 * create communication pipes between master thread
		 * and children
		 */
		if (pipe(lcore_config[i].pipe_master2slave) < 0)
			rte_panic("Cannot create pipe\n");
		if (pipe(lcore_config[i].pipe_slave2master) < 0)
			rte_panic("Cannot create pipe\n");

		lcore_config[i].state = WAIT;

		/* create a thread for each lcore */
		ret = pthread_create(&lcore_config[i].thread_id, NULL,
				     eal_thread_loop, NULL);
		if (ret != 0)
			rte_panic("Cannot create thread\n");

		/* Set thread_name for aid in debugging. */
		snprintf(thread_name, RTE_MAX_THREAD_NAME_LEN,
			"lcore-slave-%d", i);
		ret = rte_thread_setname(lcore_config[i].thread_id,
						thread_name);
		if (ret != 0)
			RTE_LOG(ERR, EAL,
				"Cannot set name for lcore thread\n");
	}
```
上述代码为每个逻辑核创建两个匿名管道，并将 lcore_config 数组中的对应项目的 state 变量设定为 WAIT 状态，然后调用 pthread_create 创建逻辑核线程，将 thread_id 保存在 lcore_config 数组中当前项目的 thread_id 中，并指定线程入口为 eal_thread_loop。最后通过 rte_thread_setname 设置线程的名称，**每个逻辑核线程在这里被称为 slave 线程**。

### 代表分发到 lcore 线程中的执行单元的成员
lcore_config 结构的如下成员描述了下发到 lcore 线程中的执行单元：

```c
	lcore_function_t * volatile f;         /**< function to call */
	void * volatile arg;       /**< argument of function */
	volatile int ret;          /**< return value of function */
```
f 指向待执行的任务单元，arg 指向任务单元附属的参数，ret 保存执行单元执行的返回值。

**eal_common_launch.c** 中实现了下发任务与获取逻辑核状态的接口，下发任务通过调用 **rte_eal_mp_remote_launch** 函数来完成。

此函数的代码如下：

```c
int
rte_eal_mp_remote_launch(int (*f)(void *), void *arg,
			 enum rte_rmt_call_master_t call_master)
{
	int lcore_id;
	int master = rte_get_master_lcore();

	/* check state of lcores */
	RTE_LCORE_FOREACH_SLAVE(lcore_id) {
		if (lcore_config[lcore_id].state != WAIT)
			return -EBUSY;
	}

	/* send messages to cores */
	RTE_LCORE_FOREACH_SLAVE(lcore_id) {
		rte_eal_remote_launch(f, arg, lcore_id);
	}

	if (call_master == CALL_MASTER) {
		lcore_config[master].ret = f(arg);
		lcore_config[master].state = FINISHED;
	}

	return 0;
}
```
此函数将任务分发到每个逻辑核线程上，分发前先检查每个逻辑核线程的状态，没有处于 WAIT 状态表明逻辑核线程已经有任务正在执行，函数直接返回。

当逻辑核线程空闲时，遍历每个逻辑核，调用 rte_eal_remote_launch 将 f 参数代表的执行单元分发到相应的逻辑核线程中。

rte_eal_remote_launch 函数的主要逻辑如下：

1. 获取 rte_eal_init 中为当前逻辑核线程创建的匿名管道，master 到 slave 的管道为 m2s，slave 到 master 的管道为 s2m。
2. 判断 slave 线程是否处于 WAIT 状态，否，则返回 -EBUSY。
3. 将 f 与 arg 参数设定到当前逻辑核线程对应的 lcore_config 项目的 f 与 arg 成员上。
4. 通过 m2s 向 slave 线程的管道写入字符 '0'。
5. 从 s2m 管道读取 slave 线程向 master 线程回复的 ack，收到回复则成功返回，未收到回复、其它异常情况则直接终止程序。

rte_eal_remote_launch 函数执行完成后，返回到 rte_eal_mp_remote_launch 函数中，判断 **call_master** 参数是否为 **CALL_MASTER**，是则在当前线程上调用 f 函数并保存返回值到 master 线程对应的 lcore_config 结构的 ret 变量中，执行完成后将 master 线程对应的 lcore_config 数组中的 state 变量设定为 FINISHED。

###  用于描述线程 cpu 亲和性及 numa 节点的成员
相关数据成员如下：

```c
	unsigned socket_id;        /**< physical socket id for this lcore */
	unsigned core_id;          /**< core number on socket for this lcore */
	int core_index;            /**< relative index, starting from 0 */
	rte_cpuset_t cpuset;       /**< cpu set which the lcore affinity to */
```
socket_id 表示逻辑核所在的物理 numa id，core_id 表示当前逻辑核所在的 numa 节点上的核数，core_index 表示从 0 开始的核下标，cpuset 表示当前逻辑核的 cpu 亲和性设置。

socket_id、core_id、core_index、cpuset 在 rte_eal_init 函数的子函数调用中被初始化，cpuset 在 eal_thread_loop 函数中被设定到对应的线程上。

eal_thread_loop 函数源码如下：

```c
/* main loop of threads */
__attribute__((noreturn)) void *
eal_thread_loop(__attribute__((unused)) void *arg)
{
	char c;
	int n, ret;
	unsigned lcore_id;
	pthread_t thread_id;
	int m2s, s2m;
	char cpuset[RTE_CPU_AFFINITY_STR_LEN];

	thread_id = pthread_self();

	/* retrieve our lcore_id from the configuration structure */
	RTE_LCORE_FOREACH_SLAVE(lcore_id) {
		if (thread_id == lcore_config[lcore_id].thread_id)
			break;
	}
	if (lcore_id == RTE_MAX_LCORE)
		rte_panic("cannot retrieve lcore id\n");

	m2s = lcore_config[lcore_id].pipe_master2slave[0];
	s2m = lcore_config[lcore_id].pipe_slave2master[1];

	/* set the lcore ID in per-lcore memory area */
	RTE_PER_LCORE(_lcore_id) = lcore_id;

	/* set CPU affinity */
	if (eal_thread_set_affinity() < 0)
		rte_panic("cannot set affinity\n");

	ret = eal_thread_dump_affinity(cpuset, RTE_CPU_AFFINITY_STR_LEN);

	RTE_LOG(DEBUG, EAL, "lcore %u is ready (tid=%x;cpuset=[%s%s])\n",
		lcore_id, (int)thread_id, cpuset, ret == 0 ? "" : "...");

	/* read on our pipe to get commands */
	while (1) {
		void *fct_arg;

		/* wait command */
		do {
			n = read(m2s, &c, 1);
		} while (n < 0 && errno == EINTR);

		if (n <= 0)
			rte_panic("cannot read on configuration pipe\n");

		lcore_config[lcore_id].state = RUNNING;

		/* send ack */
		n = 0;
		while (n == 0 || (n < 0 && errno == EINTR))
			n = write(s2m, &c, 1);
		if (n < 0)
			rte_panic("cannot write on configuration pipe\n");

		if (lcore_config[lcore_id].f == NULL)
			rte_panic("NULL function pointer\n");

		/* call the function and store the return value */
		fct_arg = lcore_config[lcore_id].arg;
		ret = lcore_config[lcore_id].f(fct_arg);
		lcore_config[lcore_id].ret = ret;
		rte_wmb();
		lcore_config[lcore_id].state = FINISHED;
	}

	/* never reached */
	/* pthread_exit(NULL); */
	/* return NULL; */
}
```
此函数的关键过程如下：

1. 获取当前线程的 thread_id
2. 使用获取到的 thread_id 在 lcore_config 数组中匹配，确定对应的 lcore_id，lcore_id 不合法则终止程序，合法则获取 m2s（主线程到从线程的匿名管道）与 s2m （从线程到主线程的匿名管道）
3. 设定每线程变量 per_lcore__lcore_id，设定后调用 pthread 库的函数设定当前线程的 cpu 亲和性
4. dump 当前线程的 cpu 亲和性
5. 从 m2s 读取主线程发送的数据，失败则直接终止程序，成功则继续执行下一步
6. 设定当前线程 lcore_config 结构中的 state 变量为 RUNNING，标志下发任务即将执行
7. 通过 s2m 向主线程发送 ack，失败则直接终止程序，成功则继续执行下一步
8. 判断当前线程 lcore_config 结构中的 f 变量值是否为空，为空则终止程序，不为空则继续执行下一步
9. 调用当前线程 lcore_config 结构中设定的 f 函数，并保存其返回值到 lcore_config 结构中的 ret 变量中，最后将 lcore_config 结构中的 state 变量设定为 FINISHED 标志下发任务执行完成。

 ### 使用每线程数据 lcore_id 的意义

 dpdk 定义了每线程数据 lcore_id，这个 lcore_id 是每个线程的本地数据，它被用于快速获取 lcore_config 数组、其它全局数组中，当前线程占据的元素。

最初创建逻辑核线程时，每个 lcore_config 数组中不同项目的 thread_id 中保存了绑定到的线程的 id 号。dpdk 需要在逻辑核线程的执行函数中获取当前线程对应的 lcore_config 结构，如果每次都遍历 lcore_config 数组来确定，效率很差，同时每个逻辑核对应的 lcore_config 结构已经创建并关联后就是确定的，不会再变化。

按照我的理解，基于这两点原因，dpdk 定义了每线程数据 lcore_id，在 eal_thread_loop 函数中为这个每线程 id 赋值，赋值完成后，在每个线程中就可以以 lcore_id 为下标来获取到诸如 lcore_config 这种每个线程的结构。

## 为什么不将 lcore_config 结构也定义为每线程数据？
按照上文的描述，每个逻辑核线程都需要分配一个 lcore_config 结构，那为什么要通过全局数组，能否将 lcore_config 结构也定义为一个每线程数据来实现呢？

仔细想想这是不合理的，lcore_config 结构中的一些成员如执行单元相关的成员需要在其它线程中被访问并赋值，而在其它线程中访问到的 lcore_config 结构是本线程的 tls 变量，这样就设定不了其它线程的 lcore_config 结构的成员，故而不能将 lcore_config 结构定义为每线程数据。