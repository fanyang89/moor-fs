# 常驻文件服务 IPC v1

## 启动与范围

```sh
zig build -Doptimize=safe
zig-out/bin/nas-fs serve-files \
  127.0.0.1:7101,127.0.0.1:7102,127.0.0.1:7103 \
  /absolute/backends.json /absolute/private-parent/core-runtime 1 2
```

进程前台运行，连接既有Raft元数据集群；后端映射和初始化沿用运维文档。最后两个参数是未绑定文件迁移时使用的副本ID，已绑定文件使用元数据中记录的双副本。数据面按inode工作；命名空间支持属性、单个路径分量查找、分页列举及创建/重命名/删除。

runtime目录必须是可信父目录下尚不存在的绝对路径。服务以0700权限独占创建它，并监听其中的 `core.sock`；路径受Unix socket长度限制。启动遇到已有目录直接失败，绝不删除旧socket。当前没有SIGTERM优雅退出处理；信号退出可能留下目录。确认旧进程退出后，由运维删除这个已知socket及空目录，或使用新的runtime目录。不要删除仍被存活服务使用的目录。

这是同一OS用户内的可信本机接口。0700目录隔离其他用户，不实现SMB用户认证、ACL或对同UID进程的隔离。现有FUSE入口保留；原生读写VFS实验入口见 `samba-vfs.zh-CN.md`，尚未实现SMB用户身份映射。

## 帧与字段

每帧为4字节little-endian无符号长度，后接UTF-8 JSON，长度不包括头部。请求/响应长度均为1–132096字节；单次读写数据最多65536字节，以十六进制字符串传输任意二进制数据。较大I/O由接入端分段，多段写入不具备整体原子性。

请求：

```json
{"version":1,"request":1,"operation":{"open":{"inode":42,"writable":true}}}
```

响应：

```json
{"version":1,"request":1,"err":null,"result":{"handle":2,"size":0,"count":null,"hex":null,"attributes":null,"page":null,"change":null}}
```

`request`是调用者指定的u64关联号，原样返回，**不是去重凭据**。服务逐连接按顺序执行；v1客户端应逐请求等待响应。网络分片不改变帧边界，连续帧分别处理。连接ID由服务分配，协议没有owner字段，不能替其他连接使用句柄。

`operation`必须且只能选择以下一个成员：

| 操作 | 字段 | 成功result |
| --- | --- | --- |
| open | inode:u64, writable:bool | handle, size |
| open_guarded | path:{source:{inode,parent,name},ancestors:[{inode,parent,name},...]}, writable:bool | handle, size |
| create_open | request_id:u64, parent:u64, name:string, ancestors:[{inode,parent,name},...], writable:bool | change:{status,inode}, handle, size |
| read | handle:u64, offset:u64, length:u32 | count, hex；EOF返回0/空串 |
| write | handle:u64, offset:u64, hex:string | count |
| truncate | handle:u64, length:u64 | 全null |
| size | handle:u64 | size |
| sync | handle:u64 | 全null |
| close | handle:u64 | 全null |
| stat | inode:u64 | attributes:{node,size} |
| lookup | parent:u64, name:string | attributes:{node,size} |
| list | parent:u64, after:?string=null, limit:u8=16 | page:{entries,next} |
| change | request_id:u64, mutation:object | change:{status,inode} |

`stat/lookup`返回元数据node及单独的当前size；活跃会话复用Access验证大小，无句柄的mutable文件按需恢复后验证。immutable文件只读已发布版本大小，不因stat迁移。node.mutable_file中的size/序号仍是Raft checkpoint值，不能代替外层size。

`list`每页1–16项，next是下一页after的名字游标；返回元数据节点，不逐项扫描文件，不承诺实时size。分页间目录可能变化，这不是目录快照。名称校验沿用UTF-8、255字节上限及ASCII大小写不敏感规则。

修改示例：

```json
{"version":1,"request":2,"operation":{"change":{"request_id":123456,"mutation":{"create":{"parent":1,"name":"example","kind":"file"}}}}}
```

mutation支持create:{parent,name,kind}、rename:{inode,parent,name}、remove:{inode}，以及rename_checked:{source:{inode,parent,name},parent,name}、remove_checked:{inode,parent,name}；kind为file/directory。create强制双副本，即使父目录被外部设为单副本。rename不覆盖已有目标，允许持有句柄时重命名；两种remove在本服务有任意该inode句柄时返回FileBusy。删除只改命名空间，旧数据目录仍保留，不隐式回收。

时间修改为 `set_times:{inode,atime?,mtime?,ctime?,birthtime?}`，每个非null字段为 `{seconds:i64,nanoseconds:u32}`；省略/null保持原值，至少提供一项。支持文件和目录，按inode提交Raft并保存回执；所有字段验证成功后才修改。秒范围[-11644473600,253402300799]，纳秒范围[0,999999999]。node.times返回四种时间，旧记录缺省为1704067200秒/0纳秒。显式时间更新独立于数据WAL。

核心Access在每次非空write和每次truncate完成双副本数据更新及验证后，以接入机实时时钟同一取样提交mtime/ctime，Raft确认后才返回成功。atime/birthtime保持原值，零字节write不更新；同长度truncate仍更新时间。时间提交失败或结果不确定会冻结共享会话，需释放全部句柄后重开。失败操作的数据可能已持久化，重开恢复不补造时间；WAL和时间没有跨存储原子性。sync/close、迁移、恢复、读和stat不自动改时间，因此不会覆盖后续显式设置值。创建及命名空间自动时间尚未接入。

每个上述核心操作仍新增一次Raft提交，包括VFS拆分的每个64KiB写段；自动时间不再消耗receipt，而是在node.modification保存一条generation/next_sequence/time记录。此字段缺省为null，属于内部去重状态，不是客户端应写的时间属性。核心checkpoint按当前序号/大小去重，首次attach也已改为每inode一条绑定记录，均不消耗receipt。显式set_times、命名空间及旧mutable_file命令仍受8192个集群共享回执且无GC的限制。

内部Raft命令touch_modified使用request_id=0及 `{inode,modification:{generation,next_sequence,time}}`，不开放为IPC change操作；IPC修改仍要求非零去重ID。文件代际必须匹配，合法的新序号须同时大于已有自动时间序号和已发布checkpoint序号。最近同序号同内容重试返回ok但不重新改时间；同序号不同内容返回request_conflict，旧序号返回sequence_conflict。显式时间不清除此记录，后续旧自动请求不能覆盖它；checkpoint之后精确重放最近自动请求也仍是无操作成功。所有Raft节点和核心须统一升级，不支持混合旧二进制。

C ABI新增nas_ipc_set_times，mask位为atime=1、mtime=2、ctime=4、birthtime=8；零mask本地成功且不发送请求，无效mask/时间在发送前返回EINVAL。nas_attr新增nas_times，调用方及模块必须同步重建；新set_times命令要求统一升级全部Raft节点和核心。

核心sync/close/恢复通过内部Raft命令 `checkpoint_mutable:{inode,generation,expected_sequence,next_sequence,size}` 提交，request_id=0，不开放为IPC change。新目标要求代际匹配、expected_sequence等于当前checkpoint、next_sequence严格递增且不落后于自动时间序号。若目标已是当前checkpoint且大小相同，则无操作成功；此时expected_sequence只需合法且小于目标序号，不作为重放身份。同目标不同大小返回request_conflict，旧目标或新目标CAS不匹配返回sequence_conflict。不会修改时间，也不保留历史响应；旧mutable_file.checkpoint仍使用非零ID及回执，原语义不变。自动时间、检查点、关闭及恢复可在回执表已满时继续；新建文件、显式修改仍可能因容量不足失败。此命令要求核心及全部Raft节点统一升级。

首次绑定通过内部 `attach_mutable:{inode,expected_version,file:{generation,next_sequence,size,backends}}`、request_id=0提交。初次执行仍验证未绑定、源版本CAS、双副本策略及不同故障域；成功时在同一事务设置mutable_file并保存原请求到node.attachment。相同完整请求重试成功且不重设后来的序号/大小/时间；同代际但参数不同返回request_conflict，其他代际返回storage_conflict。每inode只保留一条记录，删除inode也删除记录，旧请求不会绑定同名新inode。旧记录缺省attachment=null，旧已绑定inode不补造记录，继续直接打开；旧mutable_file.attach及原回执语义不变。回执表满时，已有空文件或不可变文件仍可首次绑定/迁移。绑定仍只是元数据声明，不保证跨NAS原子事务或回收失败迁移的孤儿目录。全部Raft节点和核心需统一升级。

`change.request_id`不同于外层关联号：它是全Raft集群共享的非零去重ID，调用者应生成随机u64并对同一修改保持ID和完整参数。重连后可重放；不同请求复用ID返回request_conflict。Raft结果在result.change.status中，包括ok、not_found、already_exists、not_empty等；这类业务拒绝的顶层err仍为null。FileBusy等本地前置拒绝不会写入Raft receipt，可在句柄释放后重试。receipt容量仍有上限，未实现GC。

旧rename/remove保留按inode操作的语义。checked变体在同一次状态机执行/LMDB事务中核对源inode的parent和精确name，再修改；源inode消失或任一字段不同返回entry_conflict，并保存冲突回执。name应取lookup返回的规范名称，而不是用户输入的大小写别名。单独的checked变体仅保护最终源目录项。

原生VFS使用 `path_guarded:{ancestors:[{inode,parent,name},...],mutation:{rename:{source:{inode,parent,name},parent,name}}}`，同一封装还支持 `mutation:{remove:{inode,parent,name}}` 和 `mutation:{create:{parent,name,kind}}`。ancestors最多32项，不含根inode 1、不允许重复inode，必须把源父目录及改名目标父目录（创建时为目标父目录）连接到根；缺链、环或超限返回invalid_request。Raft先核对所有祖先仍为目录且parent/name完全匹配，再修改，全部在一次状态机执行/LMDB事务中完成。创建文件和目录都强制双副本策略，不继承外部单副本父目录。祖先移动、改名、删除或源变化返回entry_conflict。允许附带其他遍历过的目录条件，任何一个变化都会拒绝操作。

Raft命令JSON上限由4 KiB提高到64 KiB，以容纳32项有界路径条件及JSON转义；Unix IPC帧上限仍为132096字节。VFS以当前回调的目录fd身份为起点，收集到根的链和路径遍历结果；超过32个不同目录在本地返回ENAMETOOLONG。检查当前目录项状态，不检测移动后又移回的历史，也不回溯Samba此前取得目录fd时的路径状态。

open_guarded通过新增只读RPC `CheckPath` 执行leader ReadIndex屏障后，在一次LMDB只读事务中核对全部祖先与源文件；不写Raft日志或receipt。核心持有本地服务锁完成检查到句柄登记，拒绝路径时尚未分配句柄或触发文件迁移。冲突返回顶层err=EntryConflict（C ABI ESTALE）；非法证明返回InvalidRequest，目录源返回NotFile。已打开句柄之后仍按inode工作，不持续绑定路径。其他服务或直接元数据客户端仍可在检查快照之后改名：本接口不提供跨节点命名空间锁或fencing。旧open保持纯inode语义。

原生VFS新建文件使用create_open：在一次IPC、同一个核心服务锁内完成容量预检、guarded create、对创建回执inode执行CheckPath、打开并登记首个句柄。本服务的其他open/rename/remove不能插入这段区间。创建目录继续使用change.path_guarded.create；已有文件继续open_guarded。已有名称返回change.already_exists且handle=null；VFS非O_EXCL调用可再按已有路径打开。

create_open.request_id只标识guarded create元数据命令，不是句柄去重ID；writable控制本次打开，不进入创建回执摘要。重放成功回执会尝试重新打开原inode，并重新核验原路径、祖先及单写者限制；返回新句柄、不截断、不复用旧句柄。被移动或删除的原inode不会替换为同名新文件。容量/ID耗尽等可预知本地错误在提交创建前返回；metadata业务拒绝在result.change中，后续打开错误在顶层err中。

创建与后端打开仍非跨存储原子事务：创建提交后发生后端、分配或通信错误可能留下条目，不回滚；丢失成功响应也不能推断失败。桥接不自动重试。服务断线清理连接句柄，重试须使用新的连接句柄并明确处理元数据回执和当前路径状态。

C桥接默认连接/单请求总时限30秒，VFS通过 `nas_fs:timeout_ms` 配置1–600000 ms；原 `nas_ipc_connect` 保持ABI并采用默认值，新增 `nas_ipc_connect_timeout` 显式设置。非阻塞传输以同一个单调时钟截止点覆盖整轮请求/响应，不按碎片刷新。首次超时ETIMEDOUT并毒化，后续调用EIO，不重连或重放。该机制仅限制桥接等待，不新增服务端超时字段，不取消核心请求，也不保证后端操作和锁已停止；其他直接IPC客户端仍自行管理等待策略。

checked与path_guarded均采用新增命令，不改变旧命令的JSON和回执摘要；entry_conflict（20）由C ABI映射ESTALE，VFS不自动重试。需要所有Raft节点及核心/桥接升级后使用，不支持新旧二进制混合运行。所有本机修改和open/close串行，但其他服务实例不共享活跃句柄保护；仍不能视为完整POSIX/Windows路径与跨节点锁语义。

操作失败返回非空 `err`，目前为Zig错误名称，例如 `FileBusy`、`InvalidHandle`、`ReadOnlyHandle`、`InvalidRange`、`UnsupportedVersion`、`WalSessionFailed`；错误映射尚不是Samba errno ABI。失败响应的result各字段为null。非法JSON、未知字段/操作、超长/空帧、半帧EOF及响应发送失败均断开连接并清理句柄，不保证返回错误帧。

## 句柄、持久化与断线

- 每inode共享一个Access，只允许一个写句柄，其他连接可同时持有读句柄并看到实时内容。读句柄不保留历史快照。
- 写成功沿用双副本WAL持久化及数据更新确认；sync执行完整验证、checkpoint与元数据协调。close写句柄先sync，失败也消费句柄。读句柄close只释放引用。
- 断线释放该连接所有句柄，不等价于fsync成功；幸存句柄继续共享现有会话，最后一个句柄释放后，下一次open走WAL恢复。Access冻结状态会传播到同文件其他句柄，只有全部释放后才重新打开恢复。
- 服务重启断开全部旧连接，客户端必须重新open。句柄只在当前连接内有效，不得把旧句柄带到新连接。丢失响应时，操作可能已经完成，客户端不能假定失败或依赖request号自动去重。
- 默认最多128连接/1024句柄。每连接一个并发工作任务，每请求独立有界帧与临时分配；全局会话锁仍串行执行各文件操作。当前没有连接空闲超时，可信客户端必须及时关闭连接。
- 该接口尚无失效订阅、Samba share-mode/lease协调或跨节点fencing。外部元数据修改可能使Access冻结，不能把本机句柄互斥当作跨节点接管协议。

## 验证

```sh
zig build test-file-ipc
zig build test-file-ipc-cifs -Doptimize=safe
```

第二项复用现有双Samba/内核CIFS隔离测试环境，要求现有E2E所需的无交互sudo权限及工具。两项都启动真实三节点Raft，验证独立写进程与读连接的共享、写者互斥、句柄所有权、64KiB全字节读写、协议分片/连续帧、范围与版本错误、畸形/不完整请求清理、客户端SIGKILL释放写者，以及核心SIGKILL后的双WAL恢复。

命名空间测试覆盖分页、Unicode最大字节名称、非法名称、大小写冲突、非空目录/根目录/环保护、重命名不覆盖、活跃句柄删除拒绝、重命名后旧句柄读写、实时大小、immutable stat不迁移，以及重启后的修改结果重放；重放旧删除不影响同名新inode。

Debug本地和Safe双CIFS测试通过，Debug/Safe各110项底层单测通过。双CIFS为同机loopback Samba环境，不代表物理NAS验收；这也不是Samba VFS端到端测试。日志为 `/tmp/opencode/nas-namespace-e2e-debug.log`、`/tmp/opencode/nas-namespace-e2e-cifs-safe.log` 和 `/tmp/opencode/nas-namespace-unit-{debug,safe}.log`。
