# 更名为 moor-fs

项目由nas-fs更名为 **moor-fs**，代码包和Samba模块使用 **moor_fs**。这是用户明确授权的名称调整，MVP功能冻结继续有效。

## 名称对应

| 原名称 | 新名称 |
| --- | --- |
| nas-fs CLI | moor-fs |
| nas-fs-access 包内入口 | moor-fs-access |
| Zig包/模块 nas_fs | moor_fs |
| nas_fs.so | moor_fs.so |
| libnas-ipc.a | libmoor-ipc.a |
| src/vfs_nas_fs.c | src/vfs_moor_fs.c |
| vfs objects = nas_fs | vfs objects = moor_fs |
| nas_fs:socket / nas_fs:timeout_ms | moor_fs:socket / moor_fs:timeout_ms |
| FUSE来源 nas-fs | moor-fs |
| NAS_FS_REPAIR_STOP / NAS_FS_WRITE_STOP / NAS_FS_PUBLISH_STOP_DIR | MOOR_FS_REPAIR_STOP / MOOR_FS_WRITE_STOP / MOOR_FS_PUBLISH_STOP_DIR |

## 更新部署

1. 按现有流程关闭客户端句柄和旧接入进程；构建新CLI与匹配的Samba模块，或重新生成运行目录包。
2. 更新启动脚本中的可执行文件名、Samba模块名及配置前缀；FUSE接入使用新helper重新挂载，以匹配新的mount来源名称。
3. 保持现有元数据目录、后端root、挂载身份、凭据路径和集群ID，按原部署流程启动并进行读写验收。文档中的moor-fs目录示例用于新部署，不要求移动旧数据。

新产物不提供旧名称别名。在已有zig-out或Samba构建目录中，旧二进制/模块可能仍存在；部署时使用本次构建的新名称，不能将旧文件当作兼容入口。运行目录打包使用新目录，避免混入旧产物。

## 兼容边界

- 磁盘magic、WAL/checkpoint/seal、LMDB、Raft数据及IPC协议没有改动，不执行数据格式迁移。
- 元数据排他锁文件仍为 `nas-fs.lock`，确保新旧二进制对同一目录互斥；不要因更名删除或另建锁。
- C ABI的nas_ipc_*及内部nas_*标识保持不变，避免把品牌更名扩大为ABI变更。
- Zig要求包名与fingerprint相符，包名变更后采用编译器给出的新fingerprint；固定依赖不变。
- 新的对象发布临时文件使用.moor-fs-前缀，旧临时文件仍保留，不自动迁移或回收。
- 设计/基准中的历史名称、日志路径、提交ID和Kaneo NASFS编号保留，便于追溯。当前操作命令以README、部署和VFS文档为准。

本次修改仓库内容，不改Git历史、远端仓库地址或本地检出目录名。
