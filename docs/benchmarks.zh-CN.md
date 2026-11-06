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
