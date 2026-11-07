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

后端路径丢失/替换或同步失败会冻结整个共享会话；恢复原映射后关闭全部句柄并重新打开，恢复 WAL 并补报检查点。接入进程被杀后先确认旧进程退出，再重启 WAL 入口。不要用清空 WAL、删除可变目录或强行解除锁代替恢复；此路径尚无跨节点 fencing或自动接管，可变副本的显式密封修复见下节。

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

有效基线下，`repair-mutable` 只从完整摘要匹配的一侧复制到另一侧，已有目标保持 data inode；同步目标并读回验证。两侧都正常时成功但不复制；两侧都不匹配返回 `NoVerifiedReplica`，须寻找可信备份。没有基线返回 `MissingSeal`；摘要损坏、代次/序号冲突、元数据领先或存在待回放 WAL 时拒绝修复，不猜测正确来源。

若仅一个data文件缺失，同一命令可显式重建：两个代次目录必须已存在，两份checkpoint必须完整一致，两份seal必须有效一致，当前两份WAL均存在且为空。先独占锁定幸存data并验证完整大小/SHA-256，再以exclusive方式创建缺失目标并取得锁，同步空文件及目录项后复制、同步及读回验证。源内容/inode、逻辑元数据和控制文件内容保持不变；新目标inode不承诺与丢失前相同。普通打开和scrub仍不创建缺失data。两侧data均缺失、后端离线、目录损坏或data与控制文件同时缺失尚不支持重建。

若仅一份当前wal-N缺失，repair-mutable也可显式重建空日志，但要求两侧data均存在且完整大小/摘要已经匹配两份有效seal、两份checkpoint一致，幸存当前WAL存在且为空。持有两侧data独占锁，全部校验完成后才exclusive创建日志并同步文件和目录，不修改data，不同时尝试修复损坏数据。两份当前WAL都缺失、存在pending WAL、缺失seal/checkpoint或任一data不匹配时不创建日志。普通打开/scrub仍拒绝缺失日志。中断后若空日志已持久化，普通重开和显式修复均可继续，已有日志不被替换或截断。

复制中断会保留摘要和源文件，关闭旧进程并恢复映射后可重跑修复；新建目标可能为空或部分复制，重试继续按既有损坏目标原地修复，保持新目标inode。普通打开在目标修好前仍报错。不要手工删除摘要来绕过失败。已有双侧data时，只剩一侧有效摘要仍可使用；缺失data重建要求两份摘要完整。另一侧若存在损坏或冲突摘要则失败关闭。

下一次 write/truncate 之前，会先删除并同步两侧 `seal` 目录项；任何一步失败都会冻结会话，不追加 WAL、不修改 data。后续写入按既有 WAL 恢复，旧摘要不再有权修复新内容。普通 fsync 不自动重新封存；更新结束后需要再次执行 `seal-mutable`。因此这是静止文件保护，活跃更新期间仍只有双副本读取比对。长期开启句柄期间新发生的双侧相同损坏须由显式巡检或关闭重开检测，普通范围读取仍仅比对两侧。

所有接入和维护进程应升级到支持 seal 的版本，不混用忽略基线的旧程序。这不改变 Raft 元数据格式；seal 依赖可信后端管理，包含防意外损坏的校验和，不提供防篡改签名或硬件掉电保证。

修复中断验收：`zig build test-wal-smb -Dfuse=true -Dfault-injection=true -Doptimize=safe` 在真实双 CIFS 上分别对两个修复方向执行首块复制后、目标 fsync 后的 SIGKILL；另覆盖单data缺失后创建持久化、首块复制及目标fsync三个阶段、两个方向共六项重建中断。验证源/摘要/检查点/WAL 保留、独占锁与原地重试。无需 CIFS 的本地版本为 `zig build test-wal-fuse -Dfuse=true -Dfault-injection=true`。这些入口自动启用 `--wal-faults`，必须配套故障注入构建；不要将该构建作为常规部署产物。正常构建忽略测试暂停环境变量。

单WAL缺失另有两个方向各一次mutable_wal_created暂停/SIGKILL，位于新空日志和目录项同步之后；验证双data内容/inode、seal/checkpoint及幸存WAL字节/inode不变，持锁时拒绝其他维护，重开和重试不替换新日志inode。

若仅一份seal缺失，repair-mutable现在要求双checkpoint完整一致、双当前WAL存在且为空、双data完整大小/SHA-256已经匹配幸存seal，再通过临时文件同步、原子rename与目录同步补回seal。不会同时修复损坏data；缺失data/WAL时仍须两份seal完整，不能组合恢复。普通打开/scrub可继续验证幸存seal，但不补写它；两份seal均缺失时repair拒绝恢复旧基线。补回不改变数据、幸存seal或逻辑元数据；重试保留已恢复seal的inode。两个方向各覆盖mutable_seal_restored持久发布后的SIGKILL、锁排他及普通重开/显式重试。

checkpoint协调沿用已有普通恢复规则：一份缺失或落后时，在数据/WAL恢复验证成功后补写该侧；两份缺失、记录损坏或同序号大小冲突仍拒绝。现已避免重写匹配的checkpoint，普通打开、scrub和repair保持其字节与inode；仍同步两侧目录，以完成上次可能停在rename后的发布。创建和轮换仍发布双checkpoint。两个方向新增mutable_checkpoint_reconciled发布同步后的SIGKILL，验证幸存checkpoint及其他控制文件inode不变、锁排他、普通重开和显式重试保留补写inode。此优化不放宽缺data/WAL/seal时原有的双checkpoint证据要求。

缺失文件故障注入通过被测CIFS挂载删除，以使客户端缓存目录项/延迟句柄失效；暂停复制期间从服务端路径检查内容以避开客户端强制锁。直接从服务端删除后，客户端仍可能短时读到缓存句柄，因此不能将远端删除的瞬时可见性作为本轮保证；本轮不增加跨节点fencing或NAS缓存失效订阅。

同一套件还覆盖 seal 单侧/双侧发布后的 SIGKILL，以及 write、truncate 在单侧/双侧摘要持久失效后的 SIGKILL，共六个基线生命周期场景。中断时数据和 WAL 尚未修改；仅删除一侧时重开仍可用剩余基线验证，两侧已删除时以未封存状态恢复，修复命令必须返回 `MissingSeal`。调用者看到未完成的 FUSE 写入失败后，可在重开会话后重试，再显式建立新基线；Linux 可能将该失败报告为 `EIO`、`ENOTCONN` 或 `ECONNABORTED`，不能据错误名推断数据是否已经写入。

### 活跃 WAL 的检查点前核对

WAL 模式的 fsync/flush/关闭及容量触发的日志轮换，在发布检查点之前重新读取双侧当前 WAL，校验身份、序号、校验和、精确长度和两侧一致性，再按操作顺序核对 data 的最终长度及已修改范围。重叠写采用最后一次写入的字节，截断后扩展和稀疏间隙按零字节检查；这能发现两侧同时发生的相同损坏，只要对应内容仍由当前 WAL 证明。

核对失败会返回 I/O 错误并冻结共享会话，不推进检查点、不回收旧 WAL、不补报新的元数据大小。先保留现场，再关闭相关句柄并重开，正常恢复会验证 WAL 后重放；完整 WAL 损坏或两侧分歧仍会拒绝恢复，不能手工删除日志绕过。当前 WAL 尾部不完整只允许在重开恢复阶段按既有规则处理，在活跃会话的 fsync 中不会被静默丢弃。

核对会增加双侧 WAL 和相关数据范围的读 I/O；逻辑稀疏空洞也需要扫描，空洞很大的文件可能明显增加 fsync 延迟。内存除有界 WAL 缓冲外还有与记录数量成正比的区间索引。未被当前 WAL 修改的基线字节以及日志回收后的内容，不在该机制的可信覆盖范围内，仍需双侧读取比对和静止文件 seal。它不是跨节点写入隔离或完整的持续内容校验。

有活跃 WAL 时，read 也会在返回前用日志核对实际返回缓冲中的已覆盖范围，stat/fstat 会核对日志推导的长度；巡检先核对全部当前 WAL 证据。数据、长度或日志有误时均冻结共享会话并保留 WAL，处理方式与 fsync 失败相同。未命中当前 WAL 的范围仍只有双副本一致性检查。

当前实现对 read/size 保守地重新读取两侧完整活跃 WAL。FUSE read 回调已去掉独立的前置大小查询，直接使用经过校验的实际读取字节数；跨 EOF 短读和文件扩展不再依赖句柄保存的旧大小。独立 stat/fstat 仍核对大小，小块读取面对较大待提交日志仍有明显额外读 I/O。干净会话跳过活跃 WAL 核对路径。尚无经过失效验证的内容索引缓存，不能将本轮测试视为吞吐性能验收。

read/size 的活跃日志核对现已采用流式读取：每侧固定 64 KiB 预读，最多保留一条 1 MiB payload 记录，以及本次实际读取缓冲的一份副本；不再整份保留两侧日志或为读取建立全日志区间索引。大小查询没有读窗口副本。所有日志记录仍检查身份、序号、校验和、两侧字节一致性与精确 EOF，请求窗口之外的日志损坏也不会跳过。检查点和全量巡检仍使用原有整日志区间算法，因此它们的内存上限没有随本轮降低。流式分块改变了读取请求形态，总日志传输量不变，尚需实际 NAS 性能测试。

可用 `tools/benchmark_wal.py` 或测试入口的 `--wal-benchmark` 对干净、不同活跃 WAL 大小、checkpoint 后的 read/stat 做可重复计时。命令、首次本地/双 CIFS 结果和环境边界见 `docs/benchmarks.zh-CN.md`。首次同机测试发现空 WAL 小读也约需201 ms，应继续拆分元数据屏障和日志校验耗时；不要将该结果当作物理 NAS 吞吐验收。

后续分段计时已定位ReadIndex等待。早期优化曾在100 ms逻辑tick之间按约1 ms间隔poll请求和传输事件，保留quorum屏障及选举/超时tick设置；当前已替换为下述上游事件驱动。诊断构建使用 `-Dlatency-trace=true`，将read/size阶段和ReadIndex提交/等待耗时写入进程日志，基准自动收集；正常构建默认关闭。同机小读延迟改善不代表高负载或实际NAS验收，具体数据见基准文档。

服务端追加WAL尾部后，CIFS新句柄的stat可能暂时仍报旧长度。恢复读取会在64 MiB限制内继续读取实际尾部，再执行已有双侧前缀/校验和判断；活跃会话的精确日志末尾检查不变。完整坏记录不作为可丢弃尾巴，失败仍保留证据。

`--wal-benchmark`现自动采集voter/FUSE的进程CPU和稳定线程上下文切换：三个5秒空闲窗口，各负载至少七次且至少1秒。独立脚本可用重复的 `--process PID` 和 `--min-seconds 1` 开启；默认独立调用保持七次采样。计数不包含Samba/内核线程，切换不等于硬件唤醒或功耗。原始计数、与旧run驱动的同环境对照及计量粒度见基准文档。

当前已用raftz PR #7的事件驱动替代nas-fs自建poll循环，子模块固定 `e506a2818f610b3d3aeebb786da11378ceb391ad`，通过 `Raftor.run()` 等待请求/gRPC/停机通知，逻辑tick仍100 ms。更新源码时按仓库固定子模块提交检出，勿只更新主仓库。PR对照结果和验证范围见基准文档；普通构建默认不记录分段日志。nas-fs的 `Pending.wait()` 也已改成条件变量通知等待，不再有1 ms观察粒度：回调在互斥区内发布结果并通知，等待者检查完成状态后退出。请求超时、leader丢失和停机仍由raftz回调返回，不增加独立的提前返回路径。

诊断构建新增 `wal-verify` 七阶段计时：初始化、头部读取/认证、payload读取/拷贝、双侧payload比对、完整记录认证、窗口证据覆盖、最终EOF/数据边界核对。循环阶段累计到一次验证记录，默认构建不计时。流式read/size的payload比对现用有界8字节加载及不足8字节的尾部比较；依旧完整检查双侧内容和所有记录校验和，不缓存上次成功结果。格式、恢复和检查点全量验证流程不变。

流式日志读取保留小请求的64 KiB预读；已有预读字节耗尽后，若本次目标缓冲仍有至少64 KiB待填充，则直接读取到已有帧缓冲，不再逐64 KiB中转。直读范围不得超过会话end，任何短读失败，末尾仍另行核对实际EOF。该路径不增加工作区或减少日志认证范围，不启用OS `O_DIRECT`，也不改变写入和fsync协议。

FUSE获取共享会话时同时返回本次已验证大小，属性查询和不带截断的open直接使用它，避免随后重复扫描WAL。每次独立请求仍重新验证；O_TRUNC保留截断前检查，并在截断后重新验证大小。该结果仅用于本次调用，不能据此假定跨请求大小缓存或免校验读取。

流式校验对payload至少128 KiB的记录并行读取双侧，低于阈值保持串行预读。先提交一侧给现有Io并发执行器，当前线程读另一侧，无论哪侧失败都等待已提交任务结束后才处理结果和释放工作区。仍只保留原双帧/双预读缓冲，执行器线程/任务资源另计。只读I/O并行不改变日志比对、SHA-256、序号/EOF或失败冻结规则，失败返回可能需要等待较慢一侧完成。

CIFS 可能对服务端截短的数据按客户端缓存长度补零。EOF 探测现在也比对 WAL 已覆盖的尾部字节，能发现非零尾部被补零；若被裁掉的内容本来全是零，客户端呈现的字节仍可能一致，不能据此证明服务端物理长度。该检查不替代独立重开/服务端检查，也不承诺对管理员并发修改提供一致快照。

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
