# WAL 读取延迟基准

## 运行方式

构建 Safe 版本，再使用既有三节点测试环境。基准是可选项，默认回归不增加计时负担。

```sh
zig build -Dfuse=true -Doptimize=safe
python3 tools/test_cluster.py zig-out/bin/nas-fs --wal-fuse --wal-benchmark
python3 tools/test_e2e.py zig-out/bin/nas-fs --wal-smb --wal-benchmark
```

也可以在独占、可写的 WAL FUSE 测试挂载上单独运行：

```sh
python3 tools/benchmark_wal.py /path/to/fuse \
  --backend-roots /path/to/backend-a /path/to/backend-b --samples 31
```

脚本创建唯一命名的临时文件，结束时关闭并 unlink；其后端历史目录仍按产品现有策略保留。运行期间不要在相同后端创建其他 mutable 文件：脚本通过新目录集合识别自己的双侧 WAL。后端参数是与 FUSE 相同的本地/CIFS 路径，不是 SMB URL。脚本直接读取 WAL 长度，但不改后端数据。

文件固定为 1 MiB；先写入并 fsync，然后反复覆盖相同内容，分别积累 1、4、16 MiB 的待提交 payload，最后再次 fsync。每阶段分别测 fstat、4 KiB pread、1 MiB pread，每种先预热一次，再默认采样七次；每次都检查返回内容或大小。写入/fsync 不计入读取延迟，预热与计时后核对活跃 WAL 长度保持不变。最终检查两侧新活跃日志均为空。

每个案例向 stdout 输出一行 JSON，包含所有延迟样本、median、nearest-rank p95、客户端进程 CPU 时间、平台和实际双侧活跃 WAL 大小。七次采样的 p95 就是最大样本，不适合据此承诺尾延迟 SLA。客户端 CPU 不包括 FUSE、Raft 或 Samba 进程。计时包含 Python 调用和返回值检查；这是用户 syscall 端到端延迟，不是单个 FUSE 回调或 WAL 扫描耗时。

## 首轮结果：2026-11-06

产品实现基线 `4698d6f`，Zig 0.17.0，Safe 构建。三名 voter、FUSE 和后端均在同一 Linux 主机；CIFS 组使用两个 loopback Samba 服务和真实 CIFS 挂载。FUSE 数据读取为 direct I/O，基准不清理操作系统/NAS 缓存。这不是独立物理 NAS 或跨机网络吞吐验收。

表中为 **median / p95，单位 ms**，每格七个样本。待提交 payload 为 1、4、16 MiB 时，每侧实际活跃 WAL 分别为 1,048,800、4,195,200、16,780,800 字节；由实际 FUSE 写入拆分形成，未假定一次 pwrite 等于一条 WAL 记录。

| 阶段 | 操作 | 本地后端 | 双 CIFS 后端 |
| --- | --- | ---: | ---: |
| 干净，0 WAL | stat | 603.817 / 604.191 | 604.357 / 604.781 |
| 干净，0 WAL | read 4 KiB | 200.935 / 202.732 | 201.355 / 201.842 |
| 干净，0 WAL | read 1 MiB | 403.148 / 406.667 | 402.721 / 403.697 |
| dirty，1 MiB payload | stat | 609.976 / 612.422 | 603.772 / 604.874 |
| dirty，1 MiB payload | read 4 KiB | 201.145 / 202.013 | 201.123 / 202.284 |
| dirty，1 MiB payload | read 1 MiB | 402.194 / 402.759 | 402.440 / 403.610 |
| dirty，4 MiB payload | stat | 604.291 / 605.123 | 603.952 / 605.046 |
| dirty，4 MiB payload | read 4 KiB | 201.280 / 202.763 | 201.607 / 202.738 |
| dirty，4 MiB payload | read 1 MiB | 402.222 / 403.448 | 402.080 / 404.649 |
| dirty，16 MiB payload | stat | 604.133 / 605.189 | 603.811 / 605.883 |
| dirty，16 MiB payload | read 4 KiB | 201.338 / 201.893 | 200.979 / 202.450 |
| dirty，16 MiB payload | read 1 MiB | 402.344 / 406.302 | 403.092 / 403.781 |
| checkpoint 后，0 WAL | stat | 603.970 / 605.461 | 604.060 / 605.140 |
| checkpoint 后，0 WAL | read 4 KiB | 201.140 / 201.622 | 200.890 / 202.267 |
| checkpoint 后，0 WAL | read 1 MiB | 402.361 / 403.357 | 402.813 / 403.782 |

完整原始 JSON 样本及回归输出位于本轮工作机：

- `/tmp/opencode/nas-wal-benchmark-local-safe.log`
- `/tmp/opencode/nas-wal-benchmark-cifs-safe.log`

### 结论与后续定位

1. 空 WAL 已有约 201 ms 的小读延迟，stat 约 604 ms；检查点后仍如此，因此不能把主要端到端延迟直接归因于活跃日志扫描。
2. 1–16 MiB 活跃日志下未观察到明显的端到端延迟增长，但不能推导扫描免费或真实 NAS 上不受影响。测试存在预热、本机缓存、同机网络及低样本量限制。
3. 代码中 Access 每次操作查询元数据，元数据 Get 经过 ReadIndex；当前 Raft 使用 100 ms 默认 tick、heartbeat_tick=2。约 200 ms 的延迟台阶值得定位，但这些相关事实尚不能证明具体等待点就是心跳。下一轮应计时拆分元数据屏障、数据读取和 WAL 验证，再决定修改调度或读取流程。
4. 两种后端的既有 WAL FUSE 回归均通过，CIFS 组还通过 SMB/supervisor 与冷重挂检查。本轮使用普通 Safe 二进制，未运行需 fault-injection 的完整故障矩阵；产品数据路径没有修改。

## 分段定位与事件轮询优化

启用诊断构建即可采集阶段计时，普通构建不读取诊断时钟、不输出这些日志：

```sh
zig build -Dfuse=true -Doptimize=safe -Dlatency-trace=true
python3 tools/test_cluster.py zig-out/bin/nas-fs --wal-fuse --wal-benchmark
python3 tools/test_e2e.py zig-out/bin/nas-fs --wal-smb --wal-benchmark
```

测试环境自动将 FUSE 和 voter 日志中的计时附在每例 JSON 的 `stage_samples_ns`。独立脚本可用 `--trace-logs /path/to/fuse.log /path/to/node-1.log ...` 指定日志。该字段按操作保存原始纳秒数组：

- `read`：前置路径校验、元数据 current、数据大小及双侧读取、WAL核对、后置路径校验。
- `size`：路径校验、元数据 current、WAL核对、双侧大小检查。
- `read-index`：提交 ReadIndex、等待回调完成。只记录成功屏障，不记录 inode 内容。

窗口按预热后日志偏移截取，不提供跨进程 request ID 关联；并发操作或预热后的延迟日志可能落入窗口。每个 syscall 也可能触发多个回调：本轮每七次1 MiB读有14条read记录，每七次stat有14条size记录及约21条屏障记录。不能将单个阶段的median直接相加当作syscall耗时。日志输出本身会扰动运行，诊断结果不作为普通构建的严格性能保证。

### 定位结果

原驱动的空日志小读，元数据查询median为本地201.195 ms、双CIFS198.529 ms，ReadIndex等待分别为200.677 ms和197.569 ms。16 MiB活跃日志的小读WAL核对为本地33.007 ms、双CIFS46.760 ms，元数据等待则降为约168/152 ms：原先约200 ms的端到端台阶掩盖了扫描增长。

`Raftor.run()` 每轮 tick 后休眠100 ms，休眠期间没有处理新请求及远端回应。Runtime现改为单线程驱动：逻辑tick仍每100 ms推进一次，间隙调用现有 `poll()`，每轮休眠1 ms。poll不推进Raft选举/请求超时逻辑时钟；慢存储导致错过tick时不密集补发。保留原ReadIndex quorum屏障和关闭/失败处理，不引入元数据缓存。代价是每个voter空闲时约每毫秒唤醒一次；尚未测量独立机器的CPU/功耗或高负载尾延迟。

### 优化前后（同机Safe，双方均开启分段诊断）

每格为median / p95，单位ms，每例七样本：

| 后端 | 阶段 | 操作 | 原驱动 | poll驱动 |
| --- | --- | --- | ---: | ---: |
| 本地 | 空WAL | stat | 604.259 / 604.706 | 6.867 / 7.285 |
| 本地 | 空WAL | read 4 KiB | 201.435 / 201.757 | 2.391 / 2.447 |
| 本地 | 空WAL | read 1 MiB | 402.765 / 403.164 | 6.051 / 6.206 |
| 本地 | 16 MiB payload | stat | 604.178 / 604.552 | 60.653 / 62.017 |
| 本地 | 16 MiB payload | read 4 KiB | 201.353 / 203.146 | 31.270 / 32.180 |
| 本地 | 16 MiB payload | read 1 MiB | 402.227 / 403.528 | 65.653 / 66.399 |
| 双CIFS | 空WAL | stat | 604.448 / 605.266 | 9.736 / 11.639 |
| 双CIFS | 空WAL | read 4 KiB | 201.287 / 202.416 | 4.297 / 4.859 |
| 双CIFS | 空WAL | read 1 MiB | 402.959 / 404.564 | 10.794 / 11.306 |
| 双CIFS | 16 MiB payload | stat | 602.515 / 609.679 | 90.878 / 91.977 |
| 双CIFS | 16 MiB payload | read 4 KiB | 200.249 / 201.395 | 42.945 / 44.097 |
| 双CIFS | 16 MiB payload | read 1 MiB | 402.547 / 405.842 | 86.315 / 89.111 |

优化后小读中的ReadIndex等待约2.1 ms。活跃日志扫描仍然完整执行：16 MiB时本地约28.7 ms、双CIFS约38.2 ms。下一步数据路径优化可针对这些实际开销，不能复用未经重新验证的日志缓存。原始样本在工作机 `/tmp/opencode/nas-wal-trace-{local,cifs}-safe.log` 和 `/tmp/opencode/nas-wal-poll-{local,cifs}-safe.log`；本地poll基准先于恢复读取调整，但计时阶段不涉及该恢复路径。

### 快速重开暴露的CIFS长度缓存

降低延迟后，既有wal-tail损坏测试稳定暴露：服务端给687字节日志追加4字节后，重开句柄stat仍报告687，但该位置能读到尾巴。旧恢复代码按stat分配并读满，再因额外字节拒绝恢复；错误路径保持证据，但无法立即重开。

整日志读取现保留已报告长度的批量读取，再在64 MiB容量上限内继续读取实际尾部；短读仍失败，完整损坏记录仍拒绝，只有恢复允许丢弃不完整末帧。活跃会话的checkpoint/读取仍要求已确认end与序号精确匹配。新增单测用偏小/零长度提示检查后续有效记录、跨64 KiB读取、完整损坏以及残缺尾巴不会被隐藏；真实CIFS原场景不增加重试或放宽断言即可通过。

最终Debug/Safe各98项单测通过；本地Debug WAL FUSE、Safe真实双CIFS完整WAL故障矩阵（13项损坏及10项SIGKILL）、默认staging SMB回归通过，涵盖选举、leader切换、无quorum拒绝及恢复。基准继续仅代表同机预热环境。

## 进程CPU与线程切换对照

基准现在也支持Linux `/proc` 资源计量。测试入口 `--wal-benchmark` 自动传入三个voter和FUSE的PID：先记录三个5秒空闲窗口，再对各读/stat案例采样至少七次且持续至少1秒。结果仍逐例输出JSON，`samples` 是实际操作次数；不再把快速操作的七次短窗口当作可靠CPU估计。独立脚本默认仍为七次，可显式启用：

```sh
python3 tools/benchmark_wal.py /path/to/fuse \
  --backend-roots /path/to/backend-a /path/to/backend-b \
  --process 1234 --process 1235 --process 1236 --process 1237 --min-seconds 1
```

`wal-idle`记录空闲窗口，`wal-fuse`记录负载窗口；两者的`process_resources`包含实际窗口时长、CPU tick差值及频率、CPU秒数、单核百分比，以及稳定存活线程的自愿/非自愿上下文切换数。CPU使用进程级utime+stime，覆盖全部线程。通过PID和启动tick检查进程替换；线程集合按TID与启动tick区分，另报新建/退出线程数，其切换次数不纳入共同存活线程统计。本轮各窗口没有线程增减。

这些计数不是硬件唤醒或功耗。进程内包含gRPC等后台线程，不能把所有上下文切换归因于Raft。`/proc`采样非原子，读取计数的成本和边界偏差也存在；短窗口的0 CPU tick表示低于计量粒度，绝不表示操作免费。本机CLK_TCK=100，单tick为10 ms，单个5秒窗口CPU分辨率约为单核0.2个百分点。CIFS服务端Samba、内核线程和Python客户端不计入本节的FUSE/voter进程CPU。

### 对照条件

基于`dff555e`，双方均为Safe、关闭latency-trace，同机本地/双loopback CIFS。对照构建仅临时将Runtime的 `driveLoop()` 调用换回 `node.run()`，保留新的WAL恢复读取和其余实现；测完已恢复poll驱动并重新构建，没有提交旧驱动切换或引入运行时选择开关。

每个环境分别测三个5秒空闲窗口，下表CPU按实际总时长加权；范围为三个voter各自15秒统计的最小/最大值：

| 后端 | 驱动 | 每voter空闲CPU（单核%） | 每voter自愿切换/秒 | 三voter合计CPU（单核%） |
| --- | --- | ---: | ---: | ---: |
| 本地 | 旧run | 0.27–0.33 | 1088–1098 | 0.93 |
| 本地 | poll | 0.33–0.47 | 1951–1958 | 1.27 |
| 双CIFS | 旧run | 0.40–0.47 | 1097–1109 | 1.33 |
| 双CIFS | poll | 0.40–0.47 | 1951–1961 | 1.33 |

FUSE空闲窗口均未累计一个CPU tick，自愿切换为零。poll相对旧run增加约850–870次自愿切换/秒/voter；本地三voter合计CPU增加约单核0.34个百分点，CIFS组在此计量粒度下无可分辨差异。该样本不足以得出无CPU代价或无功耗影响的结论，但未观察到空闲忙等占满核心。

### 无诊断日志时的持续串行小读

poll驱动、4 KiB pread、不限速循环，每例至少1秒。CPU%表示该负载下FUSE占一个核心的比例，并非整机百分比。大日志更慢、每秒完成操作更少，不能仅比较CPU%判断效率。

| 后端 | 待提交payload | 样本数 | median / p95（ms） | FUSE CPU（单核%） | FUSE CPU ms/操作 |
| --- | --- | ---: | ---: | ---: | ---: |
| 本地 | 0 | 395 | 2.500 / 2.759 | 13.95 | 0.354 |
| 本地 | 1 MiB | 225 | 4.377 / 4.884 | 50.83 | 2.267 |
| 本地 | 4 MiB | 112 | 8.871 / 9.324 | 75.78 | 6.786 |
| 本地 | 16 MiB | 35 | 29.451 / 30.682 | 91.75 | 26.857 |
| 双CIFS | 0 | 226 | 4.371 / 4.953 | 20.96 | 0.929 |
| 双CIFS | 1 MiB | 130 | 7.733 / 8.414 | 39.65 | 3.077 |
| 双CIFS | 4 MiB | 69 | 14.322 / 16.365 | 52.37 | 7.681 |
| 双CIFS | 16 MiB | 24 | 41.531 / 43.274 | 63.85 | 26.667 |

旧run对照的小读仍约201 ms。poll无诊断日志时延迟收益保持，16 MiB日志验证已使本地FUSE接近占满一个核心；下一步应定位重复校验的CPU成本，不能仅通过降低轮询频率解决，也不能跳过持久日志认证。

原始输出保存在工作机 `/tmp/opencode/nas-{poll,tick}-cpu-{local,cifs}-safe.log`。四组都通过既有本地/双CIFS WAL回归；CIFS覆盖13项损坏、SMB/supervisor和冷重挂。本轮只提交基准与文档，未改产品路径，未重复运行SIGKILL完整矩阵。`process_metrics`还通过实际忙循环与进程CPU时钟交叉检查，并验证含空格及右括号的Linux进程名解析。

## raftz PR #7：事件驱动对照

PR：https://github.com/fanyang89/raftz/pull/7

本轮固定PR提交 `e506a2818f610b3d3aeebb786da11378ceb391ad`，其base为原依赖 `d5eba2b338cfd00f2306680cc2dcafb016add3a0`。nas-fs直接调用事件驱动的 `Raftor.run()`，删除自建1 ms poll循环和对应时钟函数；仍显式配置100 ms逻辑tick。grpc-lite transport已提供通知，因此使用futex唤醒，不走无通知transport的1 ms回退。PR测试时仍为OPEN，子模块固定具体提交，不跟随分支浮动。

使用上一节相同命令和参数：Safe、关闭latency-trace、同机三voter、本地或双loopback CIFS、每例至少七次且至少1秒、三个5秒空闲窗口。轮询基线复用上一轮日志，并非同一时刻交错采样；以下是单轮对照，不是统计显著性或跨机NAS验收。

### 小读延迟与CPU

每格延迟为median / p95，单位ms；CPU ms/操作为本轮事件驱动下的FUSE进程CPU，不包含voter、Samba、内核线程：

| 后端 | 待提交payload | 原poll延迟 | PR事件驱动延迟 | PR样本数 | PR FUSE CPU ms/操作 |
| --- | --- | ---: | ---: | ---: | ---: |
| 本地 | 0 | 2.500 / 2.759 | 1.305 / 1.434 | 755 | 0.225 |
| 本地 | 1 MiB | 4.377 / 4.884 | 3.158 / 3.665 | 311 | 2.154 |
| 本地 | 4 MiB | 8.871 / 9.324 | 7.506 / 7.865 | 133 | 6.391 |
| 本地 | 16 MiB | 29.451 / 30.682 | 26.837 / 28.169 | 38 | 25.789 |
| 双CIFS | 0 | 4.371 / 4.953 | 3.079 / 3.551 | 320 | 0.750 |
| 双CIFS | 1 MiB | 7.733 / 8.414 | 5.449 / 6.983 | 173 | 2.659 |
| 双CIFS | 4 MiB | 14.322 / 16.365 | 15.567 / 16.582 | 65 | 8.154 |
| 双CIFS | 16 MiB | 41.531 / 43.274 | 42.547 / 43.301 | 24 | 25.833 |

小日志改善明显；大CIFS日志这一轮没有改善，4 MiB和16 MiB的median略高，不能宣称所有负载都更快。16 MiB时FUSE持续负载占单核约95%（本地）/62%（CIFS），完整日志验证仍是主要数据路径成本。

PR版本的其他操作：空日志stat本地3.684/3.996 ms、CIFS5.860/6.334 ms；空日志1 MiB读本地3.886/4.221 ms、CIFS9.152/9.777 ms。checkpoint后的4 KiB读本地1.302/1.472 ms、CIFS3.177/3.462 ms，改善不依赖待提交WAL状态。

### 空闲资源

三个5秒窗口按实际时长加权，范围为三个voter各自统计：

| 后端 | 驱动 | 每voter CPU（单核%） | 每voter自愿切换/秒 | 三voter合计CPU（单核%） |
| --- | --- | ---: | ---: | ---: |
| 本地 | 原poll | 0.33–0.47 | 1951–1958 | 1.27 |
| 本地 | PR事件驱动 | 0.33–0.47 | 1012–1020 | 1.27 |
| 双CIFS | 原poll | 0.40–0.47 | 1951–1961 | 1.33 |
| 双CIFS | PR事件驱动 | 0.33–0.53 | 1015–1021 | 1.27 |

全进程自愿切换下降约48%，但CPU差异在当前粒度/样本下很小，不能得出显著降低CPU或功耗的结论。剩余约千次切换来自进程内所有稳定线程，不能据此推断Raft事件驱动仍在1 ms轮询。本轮线程集合没有变化，空闲FUSE未累计CPU tick或自愿切换。

### 诊断及验证

另外用 `-Dlatency-trace=true` 跑本地分段诊断：空WAL小读median1.555 ms，元数据current约1.423 ms，屏障等待约1.052 ms。nas-fs的 `Pending.wait()` 仍按1 ms休眠检查回调完成标志，因此该等待值包含调用方观察完成的延迟，不能当作raftz本身的实际ReadIndex网络往返时间。本轮没有改动Pending等待方式，避免混入另一项优化；诊断构建数据不与无日志主表混合。

Debug/Safe各98项nas-fs单测通过；本地Debug WAL FUSE、Safe双CIFS完整WAL故障矩阵以及默认staging SMB通过，覆盖leader切换、无quorum拒绝、恢复、13项损坏、10项SIGKILL及冷重挂。直接测试PR在nas-fs里的集成，不把PR说明中的上游测试结果当成本轮重跑。

原始日志：`/tmp/opencode/nas-event-pr7-cpu-{local,cifs}-safe.log`、`/tmp/opencode/nas-event-pr7-trace-local-safe.log`、`/tmp/opencode/nas-event-pr7-unit-{debug,safe}.log`、`/tmp/opencode/nas-event-pr7-wal-fault-safe.log`、`/tmp/opencode/nas-event-pr7-staging-safe.log`。最终恢复为普通Safe构建，未推送或评论上游PR。

## nas-fs回调完成通知：移除Pending的1 ms观察粒度

在固定raftz PR提交不变的前提下，将Pending的原子完成标志加nanosleep循环替换为 `std.Io.Mutex` / `std.Io.Condition`。回调持锁拷贝响应或错误、设置done、signal并解锁；wait持锁检查done，未完成则条件等待，醒来再次检查。回调先完成时状态仍保留，等待与通知交错不会丢失唤醒；等待者重新取得锁后才允许返回并释放栈上Pending，避免只发布原子done就使通知者继续访问失效对象。

使用与grpc-lite阻塞同步相同的Io后端，不启动额外线程池。等待不可取消，不新增独立超时：raftz仍负责请求超时、leader变化和停机回调，调用方保持Pending存活直到收到完成通知。提案与ReadIndex使用相同机制，quorum语义、逻辑tick和WAL校验不变。

### 无诊断日志对照

对照基线为上一节PR集成 `8edd35a` 的日志；本轮仍为Safe、同机、本地/双loopback CIFS、每例至少七次且至少1秒。各轮并非交错重复试验，数字用于定位趋势而非SLA。下表延迟为median / p95，单位ms：

| 后端 | 操作/待提交payload | 原Pending轮询 | 通知等待 | 本轮样本数 |
| --- | --- | ---: | ---: | ---: |
| 本地 | stat / 0 | 3.684 / 3.996 | 1.323 / 1.638 | 736 |
| 本地 | read 4 KiB / 0 | 1.305 / 1.434 | 0.513 / 0.635 | 1883 |
| 本地 | read 1 MiB / 0 | 3.886 / 4.221 | 2.117 / 2.431 | 468 |
| 本地 | read 4 KiB / 1 MiB | 3.158 / 3.665 | 2.326 / 2.641 | 422 |
| 本地 | read 4 KiB / 4 MiB | 7.506 / 7.865 | 7.086 / 7.545 | 141 |
| 本地 | read 4 KiB / 16 MiB | 26.837 / 28.169 | 27.432 / 28.282 | 37 |
| 双CIFS | stat / 0 | 5.860 / 6.334 | 3.175 / 3.805 | 311 |
| 双CIFS | read 4 KiB / 0 | 3.079 / 3.551 | 2.234 / 2.696 | 439 |
| 双CIFS | read 1 MiB / 0 | 9.152 / 9.777 | 6.365 / 7.308 | 157 |
| 双CIFS | read 4 KiB / 1 MiB | 5.449 / 6.983 | 5.635 / 6.200 | 180 |
| 双CIFS | read 4 KiB / 4 MiB | 15.567 / 16.582 | 14.721 / 16.076 | 68 |
| 双CIFS | read 4 KiB / 16 MiB | 42.547 / 43.301 | 39.125 / 43.119 | 26 |

小日志/空日志延迟降低，大日志结果仍有波动，不宣称各负载均改善。空闲三个5秒窗口中，每voterCPU仍约单核0.3–0.5%，全进程自愿切换约1010–1030/秒，没有显著变化；本次消除的是请求进行中的完成轮询，不是其他线程的空闲周期工作。

额外的本地trace运行得到空WAL小读median约0.250 ms，current阶段约0.148 ms，ReadIndex提交后等待约0.034 ms，原约1.052 ms的观察台阶已消失。该次trace运行的总延迟比无日志运行还低，反映不同运行间调度/缓存等差异；不混合两组数据，也不据此声称启用日志更快。屏障计时仍包含回调通知和等待线程被调度的时间，并非纯网络RTT。

### 验证

新增两项单测：回调先完成时保留成功、ShuttingDown/LostLeadership/Timeout错误、拷贝借用响应及拒绝畸形响应；128次真实线程并发完成覆盖提案/ReadIndex成功及停机/失去leader错误，等待返回后验证结果可见。Debug/Safe各100项单测通过。本地Debug WAL FUSE、Safe双CIFS完整13项损坏和10项SIGKILL，以及默认staging SMB回归通过，保留无quorum拒绝、leader切换、关闭和恢复检查。

原始日志在 `/tmp/opencode/nas-pending-notify-cpu-{local,cifs}-safe.log`、`/tmp/opencode/nas-pending-notify-trace-local-safe.log`、`/tmp/opencode/nas-pending-notify-unit-{debug,safe}.log`、`/tmp/opencode/nas-pending-notify-wal-fault-safe.log` 和 `/tmp/opencode/nas-pending-notify-staging-safe.log`。最终构建恢复为普通Safe。下一步数据路径分析仍应针对大WAL完整认证的CPU/I/O成本。

## WAL payload比对的CPU定位与优化

诊断输出新增 `wal-verify`，每个数组为一次流式验证的七个纳秒累计值：

1. stat、读窗口及双帧缓冲初始化。
2. 双侧头部读取/比较、头部认证、长度检查（可能触发预读）。
3. 双侧payload读取及从预读缓冲拷贝。
4. 双侧payload字节相等性比较。
5. 完整记录decode及SHA-256认证，包括再次头部检查。
6. 读窗口/尾字节证据覆盖、序号和偏移推进。
7. 精确日志EOF、数据大小/尾字节/读窗口的最终验证。

循环阶段逐条累加，只在成功结束输出一条日志；普通构建不读取这些时钟。预读可能在头部阶段发生，不能将第三阶段直接当作独立NAS网络耗时。日志输出和defer清理不计在七段里，不将各段median简单相加代替端到端median。

### 实测定位

测试主机为AMD Ryzen 9 9955HX，Zig 0.17.0，Safe。本地16 MiB活跃payload、4 KiB请求下，原实现分段median约为：payload读/拷贝2.60 ms、payload比对13.91 ms、完整记录认证8.38 ms、窗口覆盖0.004 ms。瓶颈并不只是SHA-256，也不是构造窗口索引。

曾对memcmp作临时实验，比对阶段约3.98 ms；检查二进制符号/反汇编发现实际解析到compiler-rt逐字节memcmp，并非预期的系统libc优化实现，因此没有保留该外部调用。最终仅在流式双WAL payload比对使用有界8字节读取，按原始位模式比较；不足8字节的尾部继续用原字节相等判断。切片边界检查保留，没有未对齐u64指针强转、不读取payload外字节、不更改校验算法。该变化规避的是本机当前Safe构建的大payload比较开销，不断言其他CPU/编译器也有相同比例收益。

改后同类trace的payload比对约0.68 ms、读取/拷贝2.52 ms、记录认证8.41 ms。数据/记录仍完整认证，之后的主要成本转向记录校验和及双侧传输；没有缓存持久日志或跳过请求范围外的记录。

### 无日志基准

基线为上一节 `c1f3d12`，同机Safe、关闭trace、每例至少七次且至少1秒。以下为4 KiB pread的median / p95（ms），CPU列为FUSE进程每操作CPU毫秒：

| 后端 | 待提交payload | 原字节比对 | 8字节比对 | 本轮样本数 | FUSE CPU前→后 |
| --- | --- | ---: | ---: | ---: | ---: |
| 本地 | 1 MiB | 2.326 / 2.641 | 1.309 / 1.561 | 746 | 2.275 → 1.247 |
| 本地 | 4 MiB | 7.086 / 7.545 | 3.429 / 3.741 | 290 | 6.950 → 3.379 |
| 本地 | 16 MiB | 27.432 / 28.282 | 13.052 / 13.841 | 77 | 27.027 → 12.857 |
| 双CIFS | 1 MiB | 5.635 / 6.200 | 4.200 / 5.085 | 228 | 3.000 → 1.886 |
| 双CIFS | 4 MiB | 14.721 / 16.076 | 11.740 / 12.821 | 93 | 8.235 → 4.409 |
| 双CIFS | 16 MiB | 39.125 / 43.119 | 25.644 / 27.056 | 39 | 26.154 → 13.077 |

16 MiB payload时stat本轮约26.490 ms（本地）/50.119 ms（CIFS），1 MiB读约28.815/55.224 ms。空日志不进入这条比对路径，其本轮小读median约0.381/1.678 ms，不能将相对上一轮的变动归因于此次优化。跨运行未做交错重复采样，CPU tick仍有10 ms粒度；不代表独立NAS、其他架构或所有记录大小分布。

### 正确性与记录

新增三项单测：所有左右0–7字节对齐组合、0–80字节长度逐个字节翻转都检出；64 KiB前后及1 MiB payload的起点、字边界、预读边界和最后字节损坏检出；仅第二侧1 MiB记录的最后一个payload字节损坏时，即使请求只读第一个字节也返回WalDiverged、冻结并保留checkpoint。原同损日志认证、重叠写/截断/空洞和有界内存测试继续通过。

Debug/Safe各103项单测通过；本地Debug WAL FUSE、Safe真实双CIFS完整13项损坏/10项SIGKILL及SMB/supervisor、冷重挂通过。默认staging路径本轮未修改。最后恢复普通Safe构建，raftz PR固定提交及元数据通知等待均不变。

原始输出：`/tmp/opencode/nas-wal-stages-split-local-safe.log`（原分段）、`/tmp/opencode/nas-wal-memcmp-trace-local-safe.log`（临时memcmp）、`/tmp/opencode/nas-wal-word-trace-local-safe.log`（最终分段）、`/tmp/opencode/nas-wal-word-cpu-{local,cifs}-safe.log`（无日志基准）、`/tmp/opencode/nas-wal-word-unit-{debug,safe}.log`、`/tmp/opencode/nas-wal-word-fault-safe.log`。

## 大payload直接读入帧缓冲

在 `54de4be` 基线上优化LogReader：先消耗已有预读字节，预读缓冲耗尽后，如果本次readExact剩余目标长度至少64 KiB，就直接调用readPositionalAll填入已有帧缓冲；较短请求仍走64 KiB预读。这里“直读”仅指绕过用户态中转缓冲，不是 `O_DIRECT`，不改变CIFS挂载和缓存设置。

直读长度先与会话limit剩余长度比较，不超过已确认日志end；返回短读仍WalChanged，位置只在读满后推进。结束后仍探测物理EOF，payload双侧精确比对、逐帧SHA-256及窗口外日志认证全部保留。工作区仍为两个有界帧缓冲、两个64 KiB预读缓冲及实际读窗口副本，没有新增大缓冲。实际读取日志字节数不变。

这一变化让大payload不再每64 KiB发起一次用户态文件读取并拷贝；小记录的请求合并保留。没有测量SMB报文数量，底层客户端可能继续按协商尺寸拆分调用，因此不能将用户态调用次数直接等同于网络请求数量。双侧读取仍顺序执行，本轮未加入读取并发。

### 无日志基准

同机Safe、无trace，与上一节基线相同参数；每例至少七次且至少1秒。4 KiB请求的median / p95，单位ms：

| 后端 | 待提交payload | 原64 KiB中转 | 大区间直读 | 本轮样本数 | FUSE CPU ms/操作前→后 |
| --- | --- | ---: | ---: | ---: | ---: |
| 本地 | 1 MiB | 1.309 / 1.561 | 1.184 / 1.364 | 824 | 1.247 → 1.141 |
| 本地 | 4 MiB | 3.429 / 3.741 | 3.195 / 3.600 | 308 | 3.379 → 3.149 |
| 本地 | 16 MiB | 13.052 / 13.841 | 12.430 / 12.779 | 81 | 12.857 → 12.346 |
| 双CIFS | 1 MiB | 4.200 / 5.085 | 3.629 / 3.960 | 274 | 1.886 → 1.715 |
| 双CIFS | 4 MiB | 11.740 / 12.821 | 6.004 / 6.762 | 165 | 4.409 → 3.273 |
| 双CIFS | 16 MiB | 25.644 / 27.056 | 17.539 / 18.547 | 57 | 13.077 → 10.702 |

16 MiB payload时，stat本轮median本地24.967 ms、CIFS34.060 ms；1 MiB读本地27.796 ms、CIFS38.937 ms。本地收益较小，CIFS收益更明显；没有将同机loopback结果推广为真实NAS或所有小记录负载的吞吐保证。基线来自上一轮，非交错重复采样，CPU仍受10 ms计量粒度影响。

### 验证

新增两项LogReader单测：独立非均匀字节数组经过预读→大区间直读→预读→EOF仍完全一致，末尾新增字节被检出；超会话limit的直读在读取前失败且不推进位置，物理文件在预读后缩短时后续直读失败。既有最大记录、短记录混合、窗口外损坏及4 MiB校验工作区约束继续通过。

Debug/Safe各105项单测、本地Debug WAL FUSE、Safe双CIFS完整13项损坏/10项SIGKILL及SMB/supervisor、冷重挂通过。最终恢复普通Safe构建，WAL格式、Raft依赖及元数据等待机制未修改。

原始日志：`/tmp/opencode/nas-wal-direct-cpu-{local,cifs}-safe.log`、`/tmp/opencode/nas-wal-direct-unit-{debug,safe}.log`、`/tmp/opencode/nas-wal-direct-fuse-debug.log`、`/tmp/opencode/nas-wal-direct-fault-safe.log`。

## FUSE属性查询复用本次已验证大小

原共享会话路径在Client.acquire中调用Access.size检查会话，随后getNode/prepareFile又调用一次size。对脏文件，两次都扫描完整双WAL。现在acquire返回shared和本次size：现有会话验证成功才增加引用，新会话先验证再加入链表，失败时关闭Access并释放分配；getNode和不截断的prepareFile直接使用该size。

该结果只用于同一次获取调用，独立stat/open仍会验证。O_TRUNC先保留获取时校验，截断后再调用size，不能返回截断前的值。路径、当前元数据、双侧WAL和数据EOF检查仍由Access.size执行，未增加跨请求缓存。

### 验证调用次数

本地trace基准中，16 MiB dirty stat的78个样本恰有78条size、78条wal-verify和156条ReadIndex记录：每次stat一次大小验证，外层Get及current各一个屏障。旧共享会话路径每次stat出现两条size及约三条屏障。日志按时间窗口截取而非request ID关联，其他窗口仍可能带入预热后的日志；本轮dirty窗口的数量与预期一致。

### 无日志基准

基线 `ee71804`，同机Safe，沿用每例至少七次且至少1秒。下表为stat的median / p95，单位ms：

| 后端 | 阶段/待提交payload | 原重复验证 | 复用本次size | 本轮样本数 | FUSE CPU ms/操作前→后 |
| --- | --- | ---: | ---: | ---: | ---: |
| 本地 | clean / 0 | 0.498 / 0.604 | 0.617 / 0.800 | 1551 | 0.353 → 0.484 |
| 本地 | dirty / 1 MiB | 2.384 / 2.652 | 1.495 / 1.802 | 650 | 2.228 → 1.400 |
| 本地 | dirty / 4 MiB | 6.429 / 7.204 | 3.562 / 4.092 | 275 | 6.234 → 3.455 |
| 本地 | dirty / 16 MiB | 24.967 / 25.743 | 12.626 / 13.361 | 79 | 25.000 → 12.532 |
| 双CIFS | clean / 0 | 2.069 / 2.363 | 1.844 / 2.147 | 538 | 0.792 → 0.967 |
| 双CIFS | dirty / 1 MiB | 5.112 / 5.671 | 3.148 / 3.475 | 317 | 2.835 → 1.861 |
| 双CIFS | dirty / 4 MiB | 11.863 / 13.195 | 6.844 / 7.827 | 148 | 6.667 → 3.851 |
| 双CIFS | dirty / 16 MiB | 34.060 / 37.124 | 18.789 / 20.198 | 54 | 21.333 → 11.296 |

收益集中在有活跃日志时；本地空日志该轮反而略慢，不能据去掉一次调用宣称所有负载更快。基线复用上一轮，CPU tick有10 ms粒度，同机CIFS结果不代表物理NAS。文件内容read不经过本次属性结果复用，仍执行自己的完整验证。

扩展现有E2E：保持旧读句柄时O_TRUNC打开写句柄，检查路径、读句柄和写句柄均看到0大小及EOF；写入新内容但未关闭写者时再打开读句柄，检查新句柄看到当前大小和内容。既有stat长度/WAL尾部损坏场景继续严格失败，不放宽断言。本地Debug WAL FUSE、Safe双CIFS完整13项损坏/10项SIGKILL及SMB/supervisor、冷重挂通过；Python编译和fmt/diff检查通过。本轮变更在FUSE私有共享会话获取逻辑，未改底层WAL算法或C/Zig ABI。

原始日志：`/tmp/opencode/nas-size-once-trace-local-safe.log`、`/tmp/opencode/nas-size-once-cpu-{local,cifs}-safe.log`、`/tmp/opencode/nas-size-once-fuse-debug.log`、`/tmp/opencode/nas-size-once-fault-safe.log`。最终为普通Safe构建。
