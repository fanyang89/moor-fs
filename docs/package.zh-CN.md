# 原生 Linux 运行目录包

运行目录包包含 moor-fs 二进制、固定版本 libfuse、接入启停脚本、E2E 工具、文档、依赖许可证副本、构建记录与 SHA-256 清单。它不安装系统服务，不修改 `/usr`，也不携带 NAS 凭据或运行数据。

## 构建

在完整源码仓库中准备操作手册第 1 节的构建依赖，另需 binutils 的 readelf、ldd 和 sha256sum。输出目录必须不存在，其父目录必须存在：

```sh
python3 tools/deps.py init
python3 tools/package.py "$HOME/moor-fs-runtime"
```

脚本核对固定子模块并重建 libfuse，执行原生 Safe 构建，明确关闭故障注入。包内二进制仅使用 `$ORIGIN/../lib` 的运行时库路径，不引用 `.deps-build`；libfuse 按实际 SONAME 复制为普通文件。脚本从不同工作目录检查动态库解析、两个命令的 help 和全部文件校验值。

失败时保留输出目录供诊断，不覆盖已有目录；重试请使用另一个新目录。`manifest.json` 记录提交号、工作树是否有未提交变化、子模块版本、Zig、架构、构建机 libc 和外部共享库名称。工作树有变化的测试包会明确标记 dirty；不能仅凭其 commit 字段复原全部源文件。当前不保证不同机器构建出的包字节完全一致。

## 布局与启动

```text
bin/moor-fs                 CLI、元数据和 FUSE 服务
bin/moor-fs-access          相对路径启动接入 helper 的入口
lib/libfuse3.so.*           与构建匹配的 libfuse
tools/                     Python helpers 与端到端验收脚本
docs/                      中文设计、操作和打包说明
licenses/                  固定依赖的许可证副本及来源说明
manifest.json              构建与运行库记录
SHA256SUMS                 文件完整性清单（不包含它自身）
```

可整体移动或压缩目录，在同架构且运行库兼容的 Linux 主机使用。例如：

```sh
tar -C "$HOME" -czf moor-fs-runtime.tar.gz moor-fs-runtime
```

解压到目标机器后，先从包根目录执行 `sha256sum -c SHA256SUMS`，再设置包绝对路径：

```sh
BUNDLE="$HOME/moor-fs-runtime"
"$BUNDLE/bin/moor-fs" --help
"$BUNDLE/bin/moor-fs-access" --help
```

参考 `docs/operations.zh-CN.md` 启动三 voter、挂载/登记/初始化 NAS，将其中 BIN 设置为 `$BUNDLE/bin/moor-fs`。不要在包内保存元数据或配置，便于整体替换程序目录。接入机启动示例：

```sh
EP=192.0.2.21:8001,192.0.2.22:8001,192.0.2.23:8001
mkdir -p "$HOME/nas-mount"
"$BUNDLE/bin/moor-fs-access" "$EP" "$HOME/nas-mount" "$HOME/nas-access-state-01" \
  --backends "$HOME/backends.json" --write-backends 1,2 --port 1445
```

地址与路径需替换；省略 `--write-backends` 即只读。从包内直接运行 serve_access.py 时必须显式传 `--executable "$BUNDLE/bin/moor-fs"`；推荐使用 bin/moor-fs-access，避免依赖当前工作目录。请直接调用包内入口路径，不依赖把该 shell 入口单独复制或软链接到其他位置。

## 目标机依赖与验收

这是本机 ABI 运行目录包，不是静态二进制或跨发行版通用镜像。目标机仍需兼容的动态加载器/glibc，以及 manifest 中列出的系统库（当前构建包括 liburing、libnuma）。Samba、cifs-utils、fusermount3、Python 3 和内核 CIFS/FUSE 支持仍由目标系统提供；随包 libfuse 不安装 setuid 挂载工具。目标机无需 Zig、Meson 或源码树即可运行。

校验清单用于检测文件改变，不是签名或独立的发布者身份认证。运行 E2E 可能产生 Python `__pycache__`，清单仍验证原始交付文件。

从包外目录验证整个真实 SMB 路径（需要操作手册列出的 sudo -n 权限）：

```sh
python3 "$BUNDLE/tools/test_e2e.py" "$BUNDLE/bin/moor-fs" --smb
```

该测试使用包内二进制、helpers 与测试脚本；覆盖 CIFS、三节点元数据、FUSE/SMB、初始化、修复、启停清理与重启。正常包没有故障注入，不给它传 `--repair-faults`。迁移运行目录后的本机 E2E 不代表已完成独立机器、不同发行版或硬件断电验收。系统服务集成与完整备份恢复仍待完成。
