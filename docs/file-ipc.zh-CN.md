# 常驻文件服务 IPC v1

## 启动与范围

```sh
zig build -Doptimize=safe
zig-out/bin/nas-fs serve-files \
  127.0.0.1:7101,127.0.0.1:7102,127.0.0.1:7103 \
  /absolute/backends.json /absolute/private-parent/core-runtime 1 2
```

进程前台运行，连接既有Raft元数据集群；后端映射和初始化沿用运维文档。最后两个参数是未绑定文件迁移时使用的副本ID，已绑定文件使用元数据中记录的双副本。IPC按inode工作，文件创建、路径查找等命名空间操作仍通过既有元数据接口完成。

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
{"version":1,"request":1,"err":null,"result":{"handle":2,"size":0,"count":null,"hex":null}}
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

操作失败返回非空 `err`，目前为Zig错误名称，例如 `FileBusy`、`InvalidHandle`、`ReadOnlyHandle`、`InvalidRange`、`UnsupportedVersion`、`WalSessionFailed`；错误映射尚不是Samba errno ABI。失败响应的result各字段为null。非法JSON、未知字段/操作、超长/空帧、半帧EOF及响应发送失败均断开连接并清理句柄，不保证返回错误帧。

## 句柄、持久化与断线

- 每inode共享一个Access，只允许一个写句柄，其他连接可同时持有读句柄并看到实时内容。读句柄不保留历史快照。
- 写成功沿用双副本WAL持久化及数据更新确认；sync执行完整验证、checkpoint与元数据协调。close写句柄先sync，失败也消费句柄。读句柄close只释放引用。
- 断线释放该连接所有句柄，不等价于fsync成功；幸存句柄继续共享现有会话，最后一个句柄释放后，下一次open走WAL恢复。Access冻结状态会传播到同文件其他句柄，只有全部释放后才重新打开恢复。
- 服务重启断开全部旧连接，客户端必须重新open。句柄只在当前连接内有效，不得把旧句柄带到新连接。丢失响应时，操作可能已经完成，客户端不能假定失败或依赖request号自动去重。
- 默认最多128连接/1024句柄。每连接一个并发工作任务，每请求独立有界帧与临时分配；全局会话锁仍串行执行各文件操作。当前没有连接空闲超时，可信客户端必须及时关闭连接。
- 该接口尚无命名空间操作、失效订阅、Samba share-mode/lease协调或跨节点fencing。外部元数据修改可能使Access冻结，不能把本机句柄互斥当作跨节点接管协议。

## 验证

```sh
zig build test-file-ipc
zig build test-file-ipc-cifs -Doptimize=safe
```

第二项复用现有双Samba/内核CIFS隔离测试环境，要求现有E2E所需的无交互sudo权限及工具。两项都启动真实三节点Raft，验证独立写进程与读连接的共享、写者互斥、句柄所有权、64KiB全字节读写、协议分片/连续帧、范围与版本错误、畸形/不完整请求清理、客户端SIGKILL释放写者，以及核心SIGKILL后的双WAL恢复。

Debug本地和Safe双CIFS测试通过，Debug/Safe各109项底层单测通过。双CIFS为同机loopback Samba环境，不代表物理NAS验收；这也不是Samba VFS端到端测试。日志为 `/tmp/opencode/nas-ipc-e2e-debug.log`、`/tmp/opencode/nas-ipc-e2e-cifs-safe.log` 和 `/tmp/opencode/nas-ipc-unit-{debug,safe}.log`。
