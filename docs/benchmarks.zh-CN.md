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
