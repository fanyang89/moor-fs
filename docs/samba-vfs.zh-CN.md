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
nas_fs:timeout_ms = 30000
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

当前仅同OS用户、单命名空间实验：smbd有效用户必须能进入核心0700目录并访问socket。尚无SMB用户到核心ACL的映射。权限由当前uid/gid、0444/0555模式（可写共享增加0222）生成；时间读取持久化元数据，新建节点由Raft leader初始化，历史缺省记录仍为2024-01-01。磁盘空间是占位值，不是NAS容量统计。虚拟device ID固定，不支持在同一Samba实例混用独立元数据集群。

每个VFS连接持有独立IPC连接，每文件使用核心句柄。Samba要求的本机fd以 `/dev/null` 占位（写句柄使用O_RDWR），仅用于fd生命周期和F_GETFL/F_SETFL/F_GETFD/F_SETFD；不用于文件内容、命名空间、文件锁或属性。所有读取经核心验证。路径引用和目录不占核心数据句柄；数据文件真正open后才获取共享Access。

IPC桥接同步等待，单次数据帧64KiB，较大的SMB读写拆分调用。pread/pwrite/fsync的send回调目前在当前线程完成后投递tevent结果，并非后台异步I/O；不宣称具备高并发生产性能。transport/协议失败关闭并毒化连接，不自动重连或重放旧句柄。

`nas_fs:timeout_ms` 指定每次连接或IPC请求的总时限，默认30000 ms，允许1–600000 ms；非法配置拒绝连接。桥接使用非阻塞Unix socket、CLOCK_MONOTONIC绝对截止点与poll，发送帧头/正文、接收帧头/正文共用同一个请求截止点；部分传输、EINTR或持续零碎响应不会重置计时。Unix连接队列已满时可能立即EAGAIN。首次超时返回ETIMEDOUT并关闭/毒化连接，之后调用立即EIO；已有句柄不能在新连接复用。每个分段IPC独立计时，不是整个SMB请求的统一上限，也不限制进程调度或其他Samba逻辑耗时。

超时不取消核心已经收到的请求、不回滚已持久化数据。核心或后端仍可能执行，直到恢复/完成后才处理断线及释放句柄；前端返回超时不表示NAS锁已经释放。SMB错误取决于触发位置：测试暂停核心时，Samba首先在共享根检查遇到超时，并映射为ACCESS_DENIED，而不是直接向客户端透传IO_TIMEOUT。调大时限前应结合实际后端/WAL耗时判断。

只读open仍沿用核心Access：必要时会迁移旧immutable文件或恢复/发布checkpoint，因此“SMB只读”不表示NAS后端无写入。读句柄看到实时变化，不保留历史快照。跨请求和分段读取也不保证快照一致性。

## 写入边界

核心统一执行每inode单写者互斥，允许共享读者；写确认仍遵循双WAL持久化后更新双完整文件的协议。支持O_EXCL、O_TRUNC、稀疏写和ftruncate，拒绝O_APPEND。关闭写句柄和fsync沿用核心checkpoint流程，验证失败向SMB返回错误。普通fsync验证待提交WAL覆盖范围，不对未触及的基线字节做全文件哈希。

文件和目录创建使用带祖先条件及Raft回执的create。新文件通过create_open在一次IPC、同一核心服务锁内创建并取得首个句柄，排除其他本地客户端插入的open/rename/remove；核心检查创建回执inode及原路径，不会打开名称被复用后的其他inode。已有名称且非O_EXCL时，VFS仍走已有文件的guarded open。目录创建无数据句柄，继续使用guarded create。

这不是跨Raft与后端文件系统的原子事务：后续打开失败或结果不确定时可能留下空文件，不回滚。创建回执可以重放，但每次打开都生成新的连接所属句柄，不重放旧句柄、不截断已有内容；当前写者占用或路径变化仍会拒绝。桥接不自动重试不确定请求。大写请求拆成多个64KiB操作，中途失败可能已有前缀持久化，甚至失败操作也可能在恢复中重放；错误不表示整个SMB写请求回滚。

VFS接收到O_SYNC/O_DSYNC时执行同步；本机libsmbclient的SMB2参数转换丢弃O_SYNC，所以测试采用 `sync always = yes` 共享验证Samba实际fsync回调及句柄关闭前checkpoint更新，不宣称已经验证客户端write-through标志。

## 验证

### 命名空间边界

mkdir、rename、unlink/rmdir均通过核心有回执的Raft change执行，使用独立随机非零request ID；桥接连接失败不自动重放。rename按inode执行，不覆盖其他已有inode；不支持交换或其他rename标志。unlink/rmdir区分文件与目录，核心拒绝根删除、非空目录、目录环和本地活跃文件句柄删除。改名不改变inode，已打开的核心句柄继续有效。删除沿用核心元数据移除语义，不宣称已完成后端孤儿数据GC。

VFS改名/删除使用path_guarded命令：将查找返回的源inode、parent、规范name，以及源/目标父目录到根的祖先目录条件交给Raft，在同一状态机执行/LMDB事务中全部比较后修改。源目录项或任一观察到的祖先变化/消失返回entry_conflict，桥接映射ESTALE，不自动重试；成功与冲突回执均可按原request ID重放。路径解析中同一目录出现矛盾观察值也在本地返回ESTALE。

文件/目录创建同样核对父目录到根的条件链，再在同一事务内创建并强制双副本策略。真实数据文件open使用open_guarded：leader ReadIndex后通过一次LMDB只读事务检查祖先和源，再建立核心句柄；此只读检查不产生Raft回执。核心锁覆盖检查到本地句柄登记，拒绝旧路径不会先迁移文件或占用写句柄。旧句柄仍可跨改名访问原inode。其他元数据写者可能在检查快照之后修改路径，此处不提供跨服务fencing。

每次最多记录32个不同的非根目录，超限返回ENAMETOOLONG；Raft命令JSON上限64 KiB，Unix IPC帧上限不变。条件链必须连接到根，缺链、重复inode或环被拒绝。观察起点是当前VFS回调持有的目录fd身份，不回溯此前Samba获取该fd时的路径；也不检测移走后又移回的历史。目录路径引用不计入核心活跃数据句柄。这仍不是完整POSIX路径原子性或SMB delete-on-close/share-mode语义。SMB持久ACL、读取atime更新和跨节点fencing仍待实现。

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

源目录项CAS验证：内存/LMDB对照与逐请求重启测试覆盖跨目录移动、名称变化、精确大小写、删除后名称复用、成功/冲突回执重放；真实Raft SMB/IPC混合测试确认移动后旧请求被拒、原文件和同名新文件均保留。Debug/Safe各111项单测、C ABI Debug/Safe及本地/双CIFS E2E通过，日志：`/tmp/opencode/nas-entry-{unit-debug,unit-safe,abi-debug,abi-safe,local,cifs}.log`。新增checked命令要求Raft节点与核心/桥接统一升级，不支持混合旧二进制运行。

这是Linux smbclient与同机loopback CIFS验证，不是Windows/macOS或物理NAS验收。下一阶段仍需路径操作原子性、持久ACL、读取atime更新、share-mode/byte-range lock/lease协调、失效通知、异步调度和跨节点fencing。

### 创建时的初始时间

新建文件和目录以Raft leader提案时的同一实时时钟取样初始化atime/mtime/ctime/birthtime，与inode创建和回执原子提交。create_open与mkdir使用的guarded create同样生效。取样作为日志注记复制，状态机重放不读时钟；回执去重忽略该注记，同一创建请求重试或leader切换后仍保留首次提交值及后续显式修改。RPC拒绝客户端伪造该注记。

旧日志没有注记时沿用原默认值；已有节点不补造创建时间。父目录及改名时间按下节自动维护，读atime仍未自动更新。创建和命名空间取时来自leader，后续写入取时来自核心，不提供跨机器单调墙钟保证。此日志格式需统一升级全部Raft节点，C ABI未改变。

Debug/Safe各125项、本地/双CIFS原生SMB及完整WAL故障套件通过。单测覆盖逐请求重启、重试换取样但不改创建时间、显式时间及改名后的重放、旧默认值保留、非法注记与事务OOM回滚；真实集群覆盖leader切换/快照/全群重启后时间不变及伪造注记拒绝。SMB验证普通上传的birthtime范围、写/截断保留初始atime/birthtime、新目录四时间一致及核心重启后保留。日志前缀：`/tmp/opencode/nas-created-times-`。

### 命名空间的自动时间

创建和删除更新父目录mtime/ctime；实际改名更新源inode的ctime及新旧父目录mtime/ctime，同父目录只更新一次。源inode的atime/mtime/birthtime保持不变。大小写改名会更新时间；同父目录同名字节的无操作改名、失败操作和回执重放不更新时间。时间、命名空间和回执在同一LMDB事务提交。

leader使用独立namespace_time日志注记，创建时与creation_time共用一次取样；两者均不进入去重摘要，RPC拒绝客户端指定非null值。旧日志仅有creation_time时仍只初始化新节点，不补更新父目录。Debug/Safe各127项、本地/双CIFS原生SMB及完整WAL故障回归通过，覆盖跨目录/大小写改名、冲突失败、删除、重放保留显式时间、事务分配失败回滚及重启持久化。日志前缀：/tmp/opencode/nas-namespace-times-。

### 写入和截断的自动时间

核心Access的非空write和truncate在完成双副本WAL/数据更新及验证后，向Raft提交同一实时时钟取样作为mtime/ctime；时间也确认后才返回成功，atime/birthtime不变。零字节write不更新时间，同长度truncate仍更新。模块不依赖Samba fntimes触发此路径。后续显式时间可覆盖自动值，fsync、关闭、迁移、恢复、读及stat不覆盖它。

时间失败/不确定会冻结会话，重开能恢复已写数据，但不补造中断操作的时间；WAL与时间不是原子事务。每个64KiB写段仍新增一次Raft提交，但自动时间已改为每inode一条WAL代际/序号/时间记录去重，不消耗回执。核心checkpoint按当前序号/大小去重，首次绑定保存每inode一条原始绑定记录，均不消耗回执；显式时间、命名空间及旧mutable_file命令仍受8192个共享回执且无GC的限制。时钟回拨可使时间倒退，不提供单调墙钟保证。

首次绑定验证：Debug/Safe各124项、本地/双CIFS原生SMB、完整WAL故障套件通过。满回执表下首次打开已有空文件、迁移不可变文件及绑定丢回复后重开均成功；后续写/同步/关闭/恢复不增加回执。相同绑定在检查点推进、显式时间修改、leader切换及全群重启后重放不重置状态；同代际改参数、其他代际、错误源版本/后端均拒绝，删除后重放不绑定同名新inode。绑定记录增加node的可选JSON字段，不改变C ABI；核心和全部Raft节点仍需统一升级。日志前缀：`/tmp/opencode/nas-attachment-state-`。

检查点验证：Debug/Safe各123项、本地及双CIFS原生SMB、完整WAL FUSE/SMB故障套件通过。超过8192轮自动时间＋检查点仅保留初始化回执；满回执表下，已有绑定文件的write/fsync/truncate/close及断线恢复仍成功。最新相同目标重试无操作成功，旧序号、同目标不同大小、错误代际及落后于已确认写入的检查点均拒绝；显式时间保留。真实Raft覆盖快照追赶及全群重启后重放，旧命令原回执仍可重放。日志前缀：`/tmp/opencode/nas-checkpoint-sequence-`。

最近自动请求的精确重试不覆盖后来显式设置的时间；同序号不同内容或旧序号被拒绝。记录随LMDB和Raft快照持久化，旧节点缺少该字段时默认null；需统一升级核心和Raft节点，C结构布局本轮不变。Debug/Safe各121项、本地/双CIFS原生SMB及完整WAL故障套件通过；新测试覆盖超过8192次自动更新不增长回执、回执已满时自动时间仍可提交、逐请求重启及真实leader切换/快照/全群重启后重放不覆盖显式时间。日志前缀：`/tmp/opencode/nas-time-watermark-`。

Debug/Safe各119项、本地Debug/双CIFS Safe原生SMB及完整WAL FUSE/SMB故障套件通过。新增单测验证写/截断时间、保留atime/birthtime、零写/迁移/检查点/恢复不重设、元数据拒绝及丢回复冻结、数据失败不改时间；SMB验证普通put、未关闭写句柄、截断自动更新，随后显式设置在关闭检查点及核心重启后仍保留。日志前缀：`/tmp/opencode/nas-auto-times-`。

### 显式时间属性

文件和目录的atime、mtime、ctime、birthtime由Raft/LMDB持久化，VFS stat读取这些值。fntimes仅更新客户端提供的字段，省略字段保持原值；UTIME_NOW使用接入进程的实时时钟，同一次调用共用一个取样。只读共享拒绝设置。更新按inode执行并保存Raft回执，不因改名改变目标身份；不要求取得数据写句柄。

内部保存有符号Unix秒和纳秒，允许秒范围[-11644473600,253402300799]、纳秒小于1000000000；SMB线上精度受协议限制。旧记录缺少时间字段时默认2024-01-01 UTC，新建节点由leader初始化。普通上传实测不会自动调用fntimes；写入/截断的自动更新时间由核心负责，改名时间随命名空间事务更新，读取atime仍待实现。底层NAS文件的宿主时间不是这些逻辑属性的来源。

`nas_attr`增加时间字段，包含它的目录页与祖先数组布局也改变；必须一起重建桥接库、模块及C ABI调用方，并统一升级Raft节点与核心，不支持新旧二进制混用。

验证：Debug/Safe各116项单测、桥接Debug/Safe、本地Debug和双CIFS Safe SMB E2E通过。单测覆盖逐请求LMDB重启、部分更新、回执重放、旧字段默认值及非法快照不修改数据库；桥接验证mask、范围、nullable字段及纳秒转换。SMB验证四时间设置、仅mtime更新、目录设置、只读拒绝、allinfo及核心重启后保留。日志：`/tmp/opencode/nas-times-{unit-debug,unit-safe,abi-debug,abi-safe,local,cifs}.log`。

祖先条件验证：内存/LMDB逐请求重启和完整快照对照覆盖源祖先变化、旧祖先名称复用、目标目录变化、缺链及成功/拒绝回执重放；形状测试覆盖32项边界、超限、重复、环。真实SMB/IPC测试移动祖先目录后拒绝旧改名/删除，恢复路径后仍重放原拒绝；18层长名称目录的实际SMB改名验证超过旧4 KiB的Raft请求。Debug/Safe各113项、C ABI Debug/Safe、本地Debug/双CIFS Safe通过；日志：`/tmp/opencode/nas-ancestors-{unit-debug,unit-safe,abi-debug,abi-safe,local,cifs}.log`。

创建/open条件验证：Debug/Safe各114项、桥接Debug/Safe、本地及双CIFS E2E通过。单测覆盖守卫创建强制双副本、祖先改变后拒绝、回执重放，以及CheckPath前后完整快照不变；E2E验证旧路径拒绝创建文件/目录、拒绝读/写open（包括已有会话）、不迁移尚未打开的文件、原读句柄跨改名可用、路径恢复后可取得写句柄，18层长路径SMB读取成功。日志：`/tmp/opencode/nas-create-open-{unit-debug,unit-safe,abi-debug,abi-safe,local,cifs}.log`。

合并创建验证：Debug/Safe各115项、C ABI Debug/Safe、本地/双CIFS E2E通过。单测验证容量不足不提交创建、首次写者排他、回执重放返回新句柄且保留内容、路径移动/名称复用拒绝、后端打开失败后条目保留且无句柄/会话泄漏、修复配置后重试复用同一inode；真实两个SMB客户端并发O_EXCL仅一个成功，成功方持有写句柄，关闭后另一客户端可读。真实Raft create_open回执重放不截断；桥接验证EEXIST和成功响应必须含非零句柄，异常后毒化。日志：`/tmp/opencode/nas-combined-{unit-debug,unit-safe,abi-debug,abi-safe,local,cifs}.log`。

IPC时限验证：C ABI Debug/Safe覆盖写请求收到但无回复、半响应头、半正文、持续碎片不延长时限、超时后立即EIO且不重发、非法时限和满连接队列快速失败。本地Debug/双CIFS Safe真实SMB测试对已打开文件执行core SIGSTOP，500 ms配置下请求有界失败，服务日志确认共享根检查Connection timed out；同连接再次请求立即失败，SIGCONT后新连接下载内容一致，退出无PANIC。日志：`/tmp/opencode/nas-deadline-{abi-debug,abi-safe,local,cifs}.log`。
