# 原生 Samba VFS 读写原型

已验证链路：

```text
SMB3 smbclient → Samba 4.25.1 nas_fs VFS
                       → 本机 Unix IPC → Zig常驻核心
                       → 双副本WAL/验证 → Linux CIFS → NAS
```

这条测试入口不挂载FUSE。当前支持目录浏览、属性、读取、创建文件和目录、写入、截断、同步、非覆盖改名及文件/空目录删除。原有FUSE入口继续可用。

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
strict sync = yes
nt acl support = no
```

这里的 `/` 是核心inode 1对应的**虚拟根**，不是导出宿主根。模块要求该路径；所有分量通过IPC查找，不读取宿主同名路径，不支持符号链接与命名流。模块连接时拒绝启用SMB2 leases或oplocks的配置。可写共享改为 `read only = no`，必须保留 `strict sync = yes`，否则连接被拒绝。

当前仅同OS用户、单命名空间实验：smbd有效用户必须能进入核心0700目录并访问socket。尚无SMB用户到核心ACL的映射。属性由当前uid/gid、0444/0555权限（可写共享增加0222）、固定2024-01-01时间生成；磁盘空间是占位值，不是NAS容量统计。虚拟device ID固定，不支持在同一Samba实例混用独立元数据集群。

每个VFS连接持有独立IPC连接，每文件使用核心句柄。Samba要求的本机fd以 `/dev/null` 占位（写句柄使用O_RDWR），仅用于fd生命周期和F_GETFL/F_SETFL/F_GETFD/F_SETFD；不用于文件内容、命名空间、文件锁或属性。所有读取经核心验证。路径引用和目录不占核心数据句柄；数据文件真正open后才获取共享Access。

IPC桥接同步阻塞，单次数据帧64KiB，较大的SMB读写拆分调用。pread/pwrite/fsync的send回调目前在当前线程完成后投递tevent结果，并非后台异步I/O；不宣称具备高并发生产性能。transport/协议失败关闭并毒化连接，不自动重连或重放旧句柄。尚无IPC超时，暂停或卡住的核心会阻塞相应smbd工作进程。

只读open仍沿用核心Access：必要时会迁移旧immutable文件或恢复/发布checkpoint，因此“SMB只读”不表示NAS后端无写入。读句柄看到实时变化，不保留历史快照。跨请求和分段读取也不保证快照一致性。

## 写入边界

核心统一执行每inode单写者互斥，允许共享读者；写确认仍遵循双WAL持久化后更新双完整文件的协议。支持O_EXCL、O_TRUNC、稀疏写和ftruncate，拒绝O_APPEND。关闭写句柄和fsync沿用核心checkpoint流程，验证失败向SMB返回错误。普通fsync验证待提交WAL覆盖范围，不对未触及的基线字节做全文件哈希。

创建是有Raft回执的metadata create，随后stat/open，不是原子create+open；后续打开失败或结果不确定时可能留下空文件。大写请求拆成多个64KiB操作，中途失败可能已有前缀持久化，甚至失败操作也可能在恢复中重放；错误不表示整个SMB写请求回滚，连接失败后不自动重试。

VFS接收到O_SYNC/O_DSYNC时执行同步；本机libsmbclient的SMB2参数转换丢弃O_SYNC，所以测试采用 `sync always = yes` 共享验证Samba实际fsync回调及句柄关闭前checkpoint更新，不宣称已经验证客户端write-through标志。

## 验证

### 命名空间边界

mkdir、rename、unlink/rmdir均通过核心有回执的Raft change执行，使用独立随机非零request ID；桥接连接失败不自动重放。rename按inode执行，不覆盖其他已有inode；不支持交换或其他rename标志。unlink/rmdir区分文件与目录，核心拒绝根删除、非空目录、目录环和本地活跃文件句柄删除。改名不改变inode，已打开的核心句柄继续有效。删除沿用核心元数据移除语义，不宣称已完成后端孤儿数据GC。

路径解析与按inode提交分开执行，未加入预期父目录/名称的CAS；如果并发改变路径，操作可能作用于已被移动的原inode。目录路径引用不计入核心活跃数据句柄。这仍不是完整POSIX路径原子性或SMB delete-on-close/share-mode语义。SMB持久ACL/时间、跨节点fencing仍待实现。

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
- 只读共享拒绝创建目录；尝试读取 `etc/passwd` 不访问宿主文件。
- 可写共享创建/O_EXCL、153610字节分段二进制写、跨进程写者互斥、读者实时可见、稀疏写、截断/O_TRUNC、关闭checkpoint及sync-always句柄未关闭时checkpoint更新；标准smbclient put/覆盖/get内容一致。
- 破坏待提交WAL覆盖的数据后，SMB close返回IO_DEVICE_ERROR（本机libsmbclient映射为EINVAL）；重新打开通过WAL恢复内容。
- 人为损坏一侧数据后SMB读取失败，关闭冻结句柄后重开由双WAL恢复，再下载内容完全一致。
- 连接退出后日志无PANIC/INTERNAL ERROR，防止“下载成功但析构崩溃”被漏掉。
- C ABI受控socket测试覆盖碎片回复、半帧EOF、空/超长帧、非法JSON、错误版本/关联号、缺失/零句柄、错误映射、任意二进制和非法hex；毒化后调用直接EIO，不发起重连。
- C ABI写测试核对create/open/write/truncate/sync/close请求，创建错误映射、同步/关闭失败与短写确认毒化。
- 命名空间E2E覆盖mkdir、跨目录文件改名、目录改名、删除文件/空目录、非空目录/重名目标/目录环拒绝；改名期间保留的IPC读句柄继续可读，活跃句柄阻止SMB删除，关闭后删除成功。C ABI核对mkdir/rename/remove请求与错误映射。

本地核心Debug、双CIFS核心Safe、C ABI Debug/Safe及底层Debug/Safe各110项单测通过。两个SMB E2E均使用脚本构建的Safe桥接库和同一Samba模块，Samba自身使用其configure编译选项。日志：`/tmp/opencode/nas-vfs-local-debug.log`、`/tmp/opencode/nas-vfs-cifs-safe.log`、`/tmp/opencode/nas-ipc-abi-{debug,safe}.log`、`/tmp/opencode/nas-vfs-unit-{debug,safe}.log`。

本轮读写日志：`/tmp/opencode/nas-vfs-write-local.log`、`/tmp/opencode/nas-vfs-write-cifs.log`、`/tmp/opencode/nas-write-abi-{debug,safe}.log`、`/tmp/opencode/nas-write-unit-{debug,safe}.log`。

命名空间本地Debug/双CIFS Safe及C ABI Debug/Safe通过，日志：`/tmp/opencode/nas-namespace-{local,cifs,abi-debug,abi-safe}.log`。

这是Linux smbclient与同机loopback CIFS验证，不是Windows/macOS或物理NAS验收。下一阶段仍需路径操作原子性、持久ACL/时间属性、share-mode/byte-range lock/lease协调、失效通知、异步调度和跨节点fencing。
