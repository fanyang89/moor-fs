# nas-fs 原型部署与恢复手册

本手册面向 Linux 上的受控试部署：三个元数据 voter、两个独立物理 NAS、一个可写 SMB 入口，其余入口只读。对应 NASFS-8；已验证的功能与尚未完成的部署验收见末尾表格。

## 1. 环境与构建

- 三个 voter 使用本机持久磁盘保存各自的 LMDB/WAL，不能放到 CIFS，也不能共享同一数据目录。
- 接入机需要 Linux CIFS、`/dev/fuse`、普通用户可执行的 `fusermount3`，以及 Samba 的 `smbd`、`testparm`、`smbclient`。
- 构建需要 Zig 0.17.0、C/C++ 工具链、CMake、Meson、Ninja、pkg-config 和 Python 3。首次部署安装发行版对应依赖包后执行：

```sh
python3 tools/deps.py init
python3 tools/deps.py check
python3 tools/deps.py build-fuse
zig build -Dfuse=true -Doptimize=safe
zig build test
command -v smbd testparm smbclient mount.cifs fusermount3
test -r /dev/fuse && test -w /dev/fuse
```

构建产物使用构建目录中 libfuse 的 RPATH；目前不能仅复制一个二进制就视为完成打包。先在各目标机器构建或保持相同依赖布局。不要部署 `-Dfault-injection=true` 构建。

示例地址：元数据节点 `192.0.2.21`、`.22`、`.23`，Raft 端口 9001，API 端口 8001；NAS 为 `192.0.2.10` 和 `.11`，共享均为 `data`。这些是文档地址，执行前全部替换成实际地址。元数据是明文、无认证原型；部署在受控网络。SMB helper 是 guest 单用户入口，所有客户端以挂载用户身份操作，不提供账号隔离。

## 2. 启动元数据集群

在各 voter 上准备归运行用户所有的数据父目录；每个节点设置不同 NODE_ID 和对应 NODE_IP，使用同一个非零 32 位十六进制 CLUSTER_ID。新集群可用 `python3 -c 'import secrets; print(secrets.token_hex(16))'` 生成一次并保存；重启必须复用，不要重新生成。

以下命令分别在三个节点运行，保持前台运行并由终端或现有服务管理器收集标准错误：

```sh
NODE_ID=1
NODE_IP=192.0.2.21
CLUSTER_ID=0123456789abcdef0123456789abcdef
PEERS=1=192.0.2.21:9001,2=192.0.2.22:9001,3=192.0.2.23:9001
mkdir -p "$HOME/nas-fs-state"
zig-out/bin/nas-fs serve --node-id "$NODE_ID" --cluster-id "$CLUSTER_ID" \
  --raft-listen "$NODE_IP:9001" --api-listen "$NODE_IP:8001" \
  --data-dir "$HOME/nas-fs-state/node-$NODE_ID" --peers "$PEERS"
```

第二、第三个节点分别改为 2/.22、3/.23。数据目录绑定节点和集群身份；不能通过改参数让旧数据目录加入另一集群。`--peers` 是引导配置，修改它不等于成员变更。

接入机另开终端，从仓库根目录设置后续命令共用变量：

```sh
BIN="$PWD/zig-out/bin/nas-fs"
EP=192.0.2.21:8001,192.0.2.22:8001,192.0.2.23:8001
"$BIN" status 192.0.2.21:8001
"$BIN" status 192.0.2.22:8001
"$BIN" status 192.0.2.23:8001
"$BIN" get "$EP" 1
```

应看到一个 leader，根目录 `replicas` 为 `two`。`status` 仅为节点本地诊断；`get` 成功才代表经过线性化读屏障。后续使用三个 API 地址，让 CLI 在 leader 切换时有界重试。

## 3. 挂载 NAS、登记并初始化后端

在两个 NAS 上预建共享内的专用 `nas-fs` 目录，并给接入用户读写权限。不要将已有用户目录直接当作对象库。凭据文件在接入机本地配置，权限 0600，不放入仓库或命令行参数。

```sh
sudo -n mkdir -p /mnt/nas-a /mnt/nas-b
sudo -n mount.cifs //192.0.2.10/data /mnt/nas-a \
  -o "credentials=/etc/nas-fs/nas-a.credentials,vers=3.1.1,uid=$(id -u),gid=$(id -g),forceuid,forcegid,nosuid,nodev,noexec,cache=none,actimeo=0"
sudo -n mount.cifs //192.0.2.11/data /mnt/nas-b \
  -o "credentials=/etc/nas-fs/nas-b.credentials,vers=3.1.1,uid=$(id -u),gid=$(id -g),forceuid,forcegid,nosuid,nodev,noexec,cache=none,actimeo=0"
findmnt -M /mnt/nas-a
findmnt -M /mnt/nas-b
```

按实际 `/proc/self/mountinfo` 中的 CIFS 挂载点、UNC 和 `addr=` 编写本机 `backends.json`：

```json
[
  {"id":1,"root":"/mnt/nas-a/nas-fs","mount":{"mountpoint":"/mnt/nas-a","source":"//192.0.2.10/data","address":"192.0.2.10"}},
  {"id":2,"root":"/mnt/nas-b/nas-fs","mount":{"mountpoint":"/mnt/nas-b","source":"//192.0.2.11/data","address":"192.0.2.11"}}
]
```

在新集群登记两个不同故障域。下面的 request_id 是首次部署示例；若已使用，应换成未使用的非零 u64。重试同一请求必须保留原 ID 与原内容，不要把旧 ID 用于其他命令。检查每次 `apply` 的 JSON `status` 为 `ok`，进程退出成功不代表业务结果必定成功。

```sh
"$BIN" apply "$EP" '{"request_id":10001,"command":{"register_backend":{"id":1,"failure_domain":10}}}'
"$BIN" apply "$EP" '{"request_id":10002,"command":{"register_backend":{"id":2,"failure_domain":20}}}'
"$BIN" backend "$EP" 1
"$BIN" backend "$EP" 2
"$BIN" init-backend "$EP" backends.json 1
"$BIN" init-backend "$EP" backends.json 2
```

`init-backend` 先确认后端已登记，再校验本机映射与实际挂载，创建并同步 `import/`、`staging/`、`objects/`。root 必须预先存在。可重复运行，不上传占位文件、不分配 inode/版本、不修改副本策略，也不覆盖已有对象。命令失败可能留下部分空目录，可修复原因后重试；它不是多后端事务，也不清理已有 staging 文件。

未登记后端、缺失映射或错误挂载不能成功初始化。仅有 id/root 的旧映射会被拒绝；`allow_local:true` 只供开发，不应用于这份 NAS 部署配置。不同路径/共享/IP 不能证明物理 NAS 独立，故障域仍由管理员确认。

## 4. 启动 FUSE 和 SMB，验证首个文件

在接入机以普通用户启动 FUSE，另开终端启动 Samba，二者必须是同一用户。下面各命令在相应终端前台运行；将路径改为自己的仓库绝对路径或先进入仓库并设置第 2 节变量。

```sh
mkdir -p mountpoint
"$BIN" mount "$EP" "$PWD/mountpoint" --backends "$PWD/backends.json" --write-backends 1,2
```

确认 FUSE 挂载完成后：

```sh
python3 tools/serve_smb.py "$PWD/mountpoint" "$PWD/smb-state-01" --port 1445 --writable
```

默认仅监听 loopback；局域网试用时显式增加 `--listen 接入机IPv4`。状态目录必须是新目录，父目录须存在，建议使用短路径。每次重启更换状态目录并保留旧日志。其他接入机的 FUSE 命令省略 `--write-backends`，Samba 命令省略 `--writable`；目前不要自动切换可写入口。

在客户端验证，`smoke.txt` 应为新文件名：

```sh
printf 'nas-fs deployment check\n' > smoke-source.txt
smbclient //127.0.0.1/nas -p 1445 -N -U guest -c 'put smoke-source.txt smoke.txt'
smbclient //127.0.0.1/nas -p 1445 -N -U guest -c 'get smoke.txt smoke-download.txt'
cmp smoke-source.txt smoke-download.txt
"$BIN" lookup "$EP" 1 smoke.txt
```

从 lookup JSON 取 `id`，设为 INODE 后检查实际双副本：

```sh
INODE=2
"$BIN" get "$EP" "$INODE"
"$BIN" check-file "$EP" backends.json "$INODE"
```

不要假定示例的 2 就是实际 inode。检查 `healthy_replicas` 为 2、`all_healthy` 为 true；`check-file` 会成功输出不健康报告，不能只看退出码。

SMB 每次 write/truncate 都同步发布整个结果文件；大上传会出现已提交中间版本，覆盖可能先提交空截断，不提供整个上传的原子替换。当前上限为 4096 inode、2048 保留版本、8192 请求回执，频繁写入会很快耗尽版本；尚无 GC。

## 5. 正常停止与重启顺序

1. 停止客户端写入，关闭 SMB 文件。
2. 在 Samba helper 终端按 Ctrl-C，或由服务管理器向 helper 发 SIGTERM，等待 Samba 子进程退出。
3. 执行 `fusermount3 -u "$PWD/mountpoint"`，等待 FUSE 进程退出。
4. 接入机停止使用后再卸载 CIFS：`sudo -n umount /mnt/nas-a`、`sudo -n umount /mnt/nas-b`。
5. 如需全停元数据，最后对各 voter 的前台进程发 SIGTERM/Ctrl-C；保留全部数据目录。

重启按第 2→3→4 节顺序：相同集群/节点 ID 和数据目录启动 voter，确认根目录可读；挂载同一 NAS 共享并检查映射；`init-backend` 可重复执行；启动 FUSE 和使用新状态目录的 Samba。重新下载 smoke.txt、比较内容并检查双副本，不要重复执行首次登记请求来猜测当前状态。

## 6. 故障恢复

| 现象 | 操作与结果检查 |
| --- | --- |
| BackendIdentityRequired | 补齐 mount 身份；不要用 allow_local 绕过 NAS 校验。 |
| BackendMountMismatch | 停止该入口写入，检查真实 CIFS 挂载点/UNC/addr 及 staging、objects 是否被嵌套挂载覆盖。恢复正确共享后重新检查文件。掉挂时不要在暴露的本地路径创建对象库。 |
| ClusterUnavailable / 写入超时 | 先恢复至少两个原 voter 并等待 leader，再 get/lookup/check-file 确认实际版本。客户端失败不等于未提交；重启或换一个 request_id 不是回滚。 |
| 无健康副本 | 保留对象、元数据和日志，查明哪一副本可恢复；不要发布伪造空文件或删除旧对象。 |
| FUSE 进程被杀 | 先停 Samba，再用 fusermount3 -u 卸载断开的挂载，之后重新挂载。断开后 ismount() 可能返回 false，不能据此判断已经卸载。 |
| 一个 voter 丢失本地 metadata 子目录 | 先停该 voter，保留整个节点目录的取证副本，再用原身份重启；本地有效 snapshot/WAL 可重建 LMDB。不得删除整个节点目录冒充同一个 voter。 |

缺失副本的手动恢复（目标 backend 必须已声明在当前版本中）：

```sh
"$BIN" check-file "$EP" backends.json "$INODE"
"$BIN" repair-file "$EP" backends.json "$INODE" 2
"$BIN" check-file "$EP" backends.json "$INODE"
```

确认目标是损坏副本、另一副本完整健康后，显式允许原子替换损坏对象：

```sh
"$BIN" repair-file "$EP" backends.json "$INODE" 2 --replace-corrupt
"$BIN" check-file "$EP" backends.json "$INODE"
```

修复不改变版本元数据；并发更新时它可能修复的是启动时固定的旧版本，所以最后必须再次检查当前版本。双副本均损坏时不能凭哈希恢复字节。没有后台自动修复、完整集群备份恢复工具或副本垃圾回收；不要删除孤立对象来“清理失败写入”，其请求可能已经提交。

## 7. 日志与验收记录

- voter/FUSE：前台标准错误，交给终端重定向或已有服务管理器保存。发布失败包含 inode、expected_version 和错误名。
- Samba：每次指定的状态目录内 process.log、samba.log、smb.conf；启动失败会附加内部日志。
- E2E：`zig build test-smb -Dfuse=true -Doptimize=safe`；故障套件再加 `-Dfault-injection=true`。需要 sudo -n、私有 mount namespace 和实际 CIFS/FUSE 支持。

| 范围 | 已有证据 / 状态 |
| --- | --- |
| 初始化与挂载防护 | 实际 CIFS 空目录初始化、重复初始化、已有对象保留、未登记后端拒绝；掉挂、本地回落、错误共享和嵌套 staging 拒绝。 |
| 文件与副本恢复 | Linux smbclient 上传/覆盖/下载/目录操作，check-file、缺失/损坏修复，后端 Samba 重启与冷重挂后全对象哈希检查。 |
| 元数据/接入崩溃 | 三 voter 重选、全进程重启、LMDB 重建；十三个写入故障场景见设计文档第 31–34 节。 |
| 真实多机首次部署 | 本手册是操作入口；尚未完成独立干净机器按手册部署的签收。 |
| 服务托管与发布包 | 当前前台入口；自动依赖编排、可安装发布包和完整备份恢复尚未完成。 |
| Windows/macOS、硬件掉电 | 尚未验收，不以 Linux smbclient 或进程 SIGKILL 结果代替。 |

登记本轮实际版本、内核/Samba 版本、机器与物理故障域、操作日志和结果。全部部署项完成前，NASFS-8 保持进行中。
