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

普通构建产物使用构建目录中 libfuse 的 RPATH，不能仅复制该二进制。可在各目标机按上面步骤构建，或使用 `python3 tools/package.py 新目录` 生成带相对库路径的运行目录包，详见 `docs/package.zh-CN.md`。使用包时将后续 BIN 设为包内 bin/nas-fs，统一接入入口使用 bin/nas-fs-access。不要部署 `-Dfault-injection=true` 构建。

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

推荐在接入机以普通用户运行统一前台入口，设置第 2 节的 BIN/EP 变量后执行：

```sh
mkdir -p mountpoint
python3 tools/serve_access.py "$EP" "$PWD/mountpoint" "$PWD/access-state-01" \
  --executable "$BIN" --backends "$PWD/backends.json" --write-backends 1,2 --port 1445
```

helper 先启动并等待 FUSE，再启动 Samba；标准输出的 ready JSON 包含两个子进程 PID、端口、可写模式和 `write_mode`，表示服务启动完成，不替代数据健康检查。默认只读，默认 staging 模式下其他接入机省略 `--write-backends`。默认监听 loopback，局域网试用显式增加 `--listen 接入机IPv4`。

### 显式启用双副本 WAL 原地写入

给上述 supervisor 命令或直接 `mount` 命令增加 `--write-mode wal`，必须同时传 `--write-backends 1,2`。默认 `staging` 继续使用不可变版本发布；WAL 模式首次打开文件（包括只读打开）会把旧内容复制、校验到新可变代次并 CAS 绑定，历史对象保留。之后修改两侧完整 data 文件，不再每次复制整个文件。

普通写成功表示双侧 redo WAL 已持久化；`fsync`/flush/关闭推进数据检查点和 Raft 大小。同一挂载的读写句柄共享当前内容和实时大小；不再保证旧句柄读取旧版本。只读句柄关闭也可能同步共享会话。单 inode 暂限一个可写句柄，打开期间 unlink 返回 `EBUSY`，请先关闭相关句柄再删除。

同一文件只安排一个 WAL 接入进程：读也持有双侧独占锁，竞争挂载返回忙；默认 staging 只读入口和 `get-file`/`check-file` 等不可变对象工具不能用于已绑定可变文件。元数据 `get` 可查看 generation、backends 和检查点大小，但检查点大小可能落后于尚未 fsync 的写入，且不代表内容完整性验证。暂不支持将绑定改回 staging。

后端路径丢失/替换或同步失败会冻结整个共享会话；恢复原映射后关闭全部句柄并重新打开，恢复 WAL 并补报检查点。接入进程被杀后先确认旧进程退出，再重启 WAL 入口。不要用清空 WAL、删除可变目录或强行解除锁代替恢复；此路径尚无跨节点 fencing、自动接管和可变副本内容修复。

验收入口：`zig build test-wal-fuse -Dfuse=true`（本地后端）和 `zig build test-wal-smb -Dfuse=true -Doptimize=safe`（三 voter、双 CIFS、真实 SMB 与 supervisor）。

### 可变副本一致性巡检

WAL 普通读取现在比对两侧大小和请求范围内的字节，任一侧不一致会返回 I/O 错误并冻结共享会话。未读取的区域须用全文件巡检检查。先关闭目标 inode 在所有入口的句柄，再执行：

```sh
"$BIN" scrub-mutable "$EP" "$PWD/backends.json" INODE
```

命令仅接受已绑定的可变文件，持有双侧独占锁；有活动会话时返回 `FileBusy`。进入会话时会执行正常 WAL 恢复、数据检查点同步和元数据补报，因此它不是只读取证工具；需要保留故障原始状态时先保存后端与元数据现场。巡检本身不推进检查点、不回收旧 WAL、不复制或覆盖副本。

成功 JSON 的 `replicas_equal:true` 代表当前两份完整文件相同；`sha256` 是现场计算结果。未建立基线时 `sealed:false`，双侧相同损坏无法据此发现，不能从任意一侧自动修复。`repair-file` 仍只适用于不可变对象，不能用于可变代次。

### 静止文件基线与显式修复

关闭目标 inode 的所有句柄后，可显式同步并建立内容基线：

```sh
"$BIN" seal-mutable "$EP" "$PWD/backends.json" INODE
"$BIN" scrub-mutable "$EP" "$PWD/backends.json" INODE
"$BIN" repair-mutable "$EP" "$PWD/backends.json" INODE
```

`seal-mutable` 要求当前双侧完整内容一致，保存绑定 inode/generation/检查点序号/大小的 SHA-256；成功返回 `sealed:true`。首次建立只是认可当前一致内容，不能识别此前已发生的双侧相同损坏。已有基线不会被重新计算出的损坏内容覆盖。建立后打开文件会扫描两侧全文件验证摘要；大文件的首次 lookup/open 和显式巡检因此可能较慢。

有效基线下，`repair-mutable` 只从完整摘要匹配的一侧复制到另一侧，保留目标 data inode；同步目标并读回验证。两侧都正常时成功但不复制；两侧都不匹配返回 `NoVerifiedReplica`，须寻找可信备份。没有基线返回 `MissingSeal`；摘要损坏、代次/序号冲突、元数据领先或存在待回放 WAL 时拒绝修复，不猜测正确来源。当前只修复仍可打开、读取和锁定的 data 文件；后端离线、data 缺失和目录损坏尚不支持重建。

复制中断会保留摘要和源文件，关闭旧进程并恢复映射后可重跑修复；普通打开在目标修好前仍报错。不要手工删除摘要来绕过失败。先前只剩一侧有效摘要时仍可使用，但另一侧若存在损坏或冲突摘要则失败关闭。

下一次 write/truncate 之前，会先删除并同步两侧 `seal` 目录项；任何一步失败都会冻结会话，不追加 WAL、不修改 data。后续写入按既有 WAL 恢复，旧摘要不再有权修复新内容。普通 fsync 不自动重新封存；更新结束后需要再次执行 `seal-mutable`。因此这是静止文件保护，活跃更新期间仍只有双副本读取比对。长期开启句柄期间新发生的双侧相同损坏须由显式巡检或关闭重开检测，普通范围读取仍仅比对两侧。

所有接入和维护进程应升级到支持 seal 的版本，不混用忽略基线的旧程序。这不改变 Raft 元数据格式；seal 依赖可信后端管理，包含防意外损坏的校验和，不提供防篡改签名或硬件掉电保证。

修复中断验收：`zig build test-wal-smb -Dfuse=true -Dfault-injection=true -Doptimize=safe` 在真实双 CIFS 上分别对两个修复方向执行首块复制后、目标 fsync 后的 SIGKILL，验证源/摘要/检查点/WAL 保留、独占锁与原地重试。无需 CIFS 的本地版本为 `zig build test-wal-fuse -Dfuse=true -Dfault-injection=true`。这些入口自动启用 `--wal-faults`，必须配套故障注入构建；不要将该构建作为常规部署产物。正常构建忽略测试暂停环境变量。

挂载点必须是现有空目录；helper 对底层目录加互斥锁并拒绝已挂载路径。状态目录必须是挂载点之外的新目录，父目录须存在，建议短路径。每次重启复用原挂载点、换一个新状态目录，保留旧日志。helper 不启动 voter、不挂载 CIFS、不自动重启子进程，也不提供跨节点 writer fencing。

### 分进程调试入口

若需要分别调试，可改用以下两个前台命令，不要与统一入口同时占用一个挂载点。FUSE 与 Samba 必须是同一普通用户。

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

普通 write/truncate 直接修改两个 NAS 的 staging；成功仅表示两侧接受本次修改，不等于版本持久发布。flush/fsync/关闭时同步、校验、重命名安装两侧对象，再以 CAS 发布；O_SYNC/O_DSYNC 写入在回复前发布。覆盖截断先留在 staging，其他读者仍读已提交版本。flush 可能在上传中途发生，不提供整个上传的原子替换。当前上限为 4096 inode、2048 保留版本、8192 请求回执，频繁发布仍会耗尽版本；尚无 GC。

接入进程崩溃可能遗留 NAS staging，普通 write 已确认但未发布的数据不会自动恢复。发布报错也可能已经提交，须先查询实际版本和副本；保留已安装对象。局部修改已有文件、同一句柄发布后继续修改都可能完整复制旧版本到双 staging，但接入机不再保存整文件临时副本。

## 5. 正常停止与重启顺序

使用统一入口时，先停止客户端写入并关闭文件，再向 serve_access.py 发 SIGTERM 或 Ctrl-C；它依次停止 Samba 进程组、卸载 FUSE 并等待子进程退出。正常停止返回零，任一子进程意外退出时清理另一侧并返回非零。不要向 helper 本身发 SIGKILL 后期待自动清理；这种情况下需先停残留 Samba，再卸载 FUSE。若挂载仍被其他进程占用，卸载失败会报告错误，不会自动 lazy-unmount。

使用分进程入口时按下面顺序停止；两种方式都需最后处理 CIFS 和 voter：

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

- voter/FUSE：分进程运行时为前台标准错误；统一入口将 FUSE 日志写到状态目录的 fuse.log。发布失败包含 inode、expected_version 和错误名。
- Samba：每次指定的状态目录内 process.log、samba.log、smb.conf；启动失败会附加内部日志。
- 统一入口的 Samba 日志与配置位于状态目录的 s/ 子目录。helper 自身在标准错误报告失败及日志路径。
- E2E：`zig build test-smb -Dfuse=true -Doptimize=safe`；故障套件再加 `-Dfault-injection=true`。需要 sudo -n、私有 mount namespace 和实际 CIFS/FUSE 支持。

| 范围 | 已有证据 / 状态 |
| --- | --- |
| 初始化与挂载防护 | 实际 CIFS 空目录初始化、重复初始化、已有对象保留、未登记后端拒绝；掉挂、本地回落、错误共享和嵌套 staging 拒绝。 |
| 文件与副本恢复 | Linux smbclient 上传/覆盖/下载/目录操作，check-file、缺失/损坏修复，后端 Samba 重启与冷重挂后全对象哈希检查。 |
| 元数据/接入崩溃 | 三 voter 重选、全进程重启、LMDB 重建；十五个写入故障场景见设计文档第 31–34、38 节，包含首侧 staging 写后与双侧已确认但未发布时崩溃。 |
| 真实多机首次部署 | 本手册是操作入口；尚未完成独立干净机器按手册部署的签收。 |
| 接入启停编排 | serve_access.py 已通过实际 FUSE/SMB 的正常停止、子进程 SIGKILL、同挂载点重启与数据校验、只读默认、目录互斥与启动失败清理。 |
| 服务托管与发布包 | 已有接入前台编排和原生 Linux 运行目录包；系统服务集成、voter/CIFS 全链路编排、跨机 ABI 验收和完整备份恢复尚未完成。 |
| Windows/macOS、硬件掉电 | 尚未验收，不以 Linux smbclient 或进程 SIGKILL 结果代替。 |

登记本轮实际版本、内核/Samba 版本、机器与物理故障域、操作日志和结果。全部部署项完成前，NASFS-8 保持进行中。
