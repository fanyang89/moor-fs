# 原生 Samba VFS 只读原型

已验证链路：

```text
SMB3 smbclient → Samba 4.25.1 nas_fs VFS
                       → 本机 Unix IPC → Zig常驻核心
                       → 双副本WAL/验证 → Linux CIFS → NAS
```

这条测试入口不挂载FUSE。当前只支持目录浏览、属性与读取；SMB写入、改名、删除等尚未接入。原有FUSE入口继续可用。

## 构建

```sh
python3 tools/deps.py init
python3 tools/build_vfs.py --jobs 4
zig build -Doptimize=safe
```

需要现有C/C++工具链、Zig 0.17.0及Samba configure报告的开发依赖。Fedora环境本轮确认 `perl-Parse-Yapp` 可用；脚本不会自动安装软件。所有源码gitlink和工作区先经deps.check验证。

脚本构建固定源码的smbd及audit模块，使用Samba生成的compile_commands.json中vfs_default编译参数生成 `zig-out/lib/nas_fs.so`，静态链接Zig `libnas-ipc.a`（包含compiler runtime）。通过源码构建树中的 `bin/modules/vfs/nas_fs.so` 链接注册，不安装到系统，不替换系统Samba服务。

只使用配套的 `third_party/samba/bin/smbd`。不能因为发行版Samba版本号相同就假定模块ABI兼容。Samba的PIDL与public-header规则依赖标准 `third_party/samba/bin` 布局，脚本使用该被git忽略的生成目录，不修改子模块源码；自定义树外out目录在本环境遇到头文件路径错误，未采用源码补丁绕过。

模块以GPL-3.0-or-later构建，直接包含固定版本的上游skel_opaque.c作为显式不支持操作表，再替换已实现操作。未实现的文件系统操作不向宿主文件系统透传。Samba高层create、ACL查询、文件ID、路径拆分和锁检查使用默认策略函数，其数据/属性调用仍返回本模块。

## 运行约束

先按 `file-ipc.zh-CN.md` 启动 `nas-fs serve-files`。实验共享关键配置：

```ini
[global]
server min protocol = SMB3
smb2 leases = no

[nas]
path = /
vfs objects = nas_fs
nas_fs:socket = /absolute/core-runtime/core.sock
read only = yes
follow symlinks = no
oplocks = no
level2 oplocks = no
kernel oplocks = no
kernel share modes = no
use sendfile = no
map archive = no
store dos attributes = no
nt acl support = no
```

这里的 `/` 是核心inode 1对应的**虚拟根**，不是导出宿主根。模块要求该路径；所有分量通过IPC查找，不读取宿主同名路径，不支持符号链接与命名流。模块连接时拒绝可写共享、启用SMB2 leases或oplocks的配置。

当前仅同OS用户、单命名空间实验：smbd有效用户必须能进入核心0700目录并访问socket。尚无SMB用户到核心ACL的映射。属性由当前uid/gid、只读0444/0555权限、固定2024-01-01时间生成；磁盘空间是只读占位值，不是NAS容量统计。虚拟device ID固定，不支持在同一Samba实例混用独立元数据集群。

每个VFS连接持有独立IPC连接，每文件使用核心句柄。Samba要求的本机fd以只读 `/dev/null` 占位，仅用于fd生命周期和F_GETFL/F_SETFL/F_GETFD/F_SETFD；不用于文件内容、命名空间、文件锁或属性。所有读取经核心验证。路径引用和目录不占核心数据句柄；数据文件真正open后才获取共享Access。

IPC桥接同步阻塞，单次数据帧64KiB，较大的SMB读取拆分调用。pread_send目前在当前线程完成后投递tevent结果，并非后台异步I/O；不宣称具备高并发生产性能。transport/协议失败关闭并毒化连接，不自动重连或重放旧句柄。尚无IPC超时，暂停或卡住的核心会阻塞相应smbd工作进程。

只读open仍沿用核心Access：必要时会迁移旧immutable文件或恢复/发布checkpoint，因此“SMB只读”不表示NAS后端无写入。读句柄看到实时变化，不保留历史快照。跨请求和分段读取也不保证快照一致性。

## 验证

先构建模块，再运行：

```sh
zig build test-ipc-bridge
zig build test-ipc-bridge -Doptimize=safe
zig build test-samba-vfs
zig build test-samba-vfs-cifs -Doptimize=safe
```

测试使用私有Samba配置、状态目录、非特权高位端口和真实三节点Raft。双CIFS测试复用既有sudo隔离环境。验证范围：

- 19项目录分页、大小写查找、256KiB+尾部任意二进制SMB下载。
- 两个独立SMB客户端/工作进程并行读取核心同一写会话；IPC写者未checkpoint的新内容可由新SMB读取看到。
- 拒绝SMB写入；尝试读取 `etc/passwd` 不访问宿主文件，核心中不会创建被拒绝的目录。
- 人为损坏一侧数据后SMB读取失败，关闭冻结句柄后重开由双WAL恢复，再下载内容完全一致。
- 连接退出后日志无PANIC/INTERNAL ERROR，防止“下载成功但析构崩溃”被漏掉。
- C ABI受控socket测试覆盖碎片回复、半帧EOF、空/超长帧、非法JSON、错误版本/关联号、缺失/零句柄、错误映射、任意二进制和非法hex；毒化后调用直接EIO，不发起重连。

本地核心Debug、双CIFS核心Safe、C ABI Debug/Safe及底层Debug/Safe各110项单测通过。两个SMB E2E均使用脚本构建的Safe桥接库和同一Samba模块，Samba自身使用其configure编译选项。日志：`/tmp/opencode/nas-vfs-local-debug.log`、`/tmp/opencode/nas-vfs-cifs-safe.log`、`/tmp/opencode/nas-ipc-abi-{debug,safe}.log`、`/tmp/opencode/nas-vfs-unit-{debug,safe}.log`。

这是Linux smbclient与同机loopback CIFS验证，不是Windows/macOS或物理NAS验收。下一阶段仍需SMB写语义、路径操作原子性、持久ACL/时间属性、share-mode/byte-range lock/lease协调、失效通知、异步调度和跨节点fencing。
