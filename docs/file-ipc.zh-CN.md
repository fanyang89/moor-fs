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

这是同一OS用户内的可信本机接口。0700目录隔离其他用户，不实现SMB用户认证、ACL或对同UID进程的隔离；未来VFS适配层承担身份映射。当前SMB入口仍走FUSE，尚未接Samba自定义VFS。

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

mutation只允许create:{parent,name,kind}、rename:{inode,parent,name}或remove:{inode}；kind为file/directory。create强制双副本，即使父目录被外部设为单副本。rename不覆盖已有目标，允许持有句柄时重命名；remove在本服务有任意该inode句柄时返回FileBusy。删除只改命名空间，旧数据目录仍保留，不隐式回收。

`change.request_id`不同于外层关联号：它是全Raft集群共享的非零去重ID，调用者应生成随机u64并对同一修改保持ID和完整参数。重连后可重放；不同请求复用ID返回request_conflict。Raft结果在result.change.status中，包括ok、not_found、already_exists、not_empty等；这类业务拒绝的顶层err仍为null。FileBusy等本地前置拒绝不会写入Raft receipt，可在句柄释放后重试。receipt容量仍有上限，未实现GC。

rename/remove使用inode身份，不对先前路径查找做原子CAS。所有本机修改和open/close串行，但外部元数据客户端与其他服务实例不受这把锁约束；不能将它当作Samba完整POSIX/Windows路径操作语义。

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
