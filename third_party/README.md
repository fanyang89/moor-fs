# Third-party dependencies

The parent repository's gitlinks are the authoritative commit locks. No floating
branch is used during initialization. Source integration does not yet implement
SMB exports, a FUSE filesystem, or distributed metadata.

## Selected projects

| Project | Baseline | Role | Integration |
| --- | --- | --- | --- |
| Samba | samba-4.25.1 | Client-facing SMB server, VFS interfaces, CTDB evaluation | Standalone daemon; source submodule |
| libfuse | fuse-3.18.3 | Linux userspace filesystem adapter, low-level inode API | Source submodule; local build and C ABI link probe |
| cifs-utils | cifs-utils-7.9 | `mount.cifs` and backend mount tooling | Standalone tools; source submodule |
| grpc-lite | db3c400bf70419742ebcb42fe316ba8b754b4975 | Internal RPC and Raft transport | Source submodule, aligned with raftz's dependency pin |
| raftz | d5eba2b338cfd00f2306680cc2dcafb016add3a0 | Metadata consensus and state-machine runtime | Source submodule |

Upstream repositories:

- Samba: https://github.com/samba-team/samba
- libfuse: https://github.com/libfuse/libfuse
- cifs-utils: https://git.samba.org/cifs-utils.git
- grpc-lite: https://github.com/fanyang89/grpc-lite
- raftz: https://github.com/fanyang89/raftz

The pins are development baselines, not claims that every component is the latest
release or that the distributed combination has passed interoperability tests.

## Initialize and check

Run from the repository root:

```sh
python3 tools/deps.py init
python3 tools/deps.py check
```

Initialization uses the committed gitlinks, including nested submodules. It does
not install OS packages, mount shares, start services, or fetch Zig's transitive
package dependencies. The check verifies the working trees against the gitlinks
in the index, required source/license files, and nested checkout status.

For a fresh clone, `git clone --recurse-submodules <repository-url>` also works.
Use `git submodule update --init --recursive` after changing parent revisions.
Do not use `git submodule update --remote` for reproducible builds.

## Build libfuse and probe its C interface

Prerequisites: Linux, Python 3, a C compiler, pkg-config, Meson, Ninja, and Zig
0.17.0. Meson reports any additional platform dependency requirements.

```sh
python3 tools/deps.py build-fuse
```

This builds the pinned libfuse source using Meson/Ninja under `.deps-build/libfuse`
and compiles/runs `tools/fuse_probe.c` using `zig cc`. The probe includes the
low-level API and dynamically links the newly built library via a build-local
RPATH. It does not accidentally probe the system libfuse instead.

No root privileges, installation, FUSE mounts, or setuid changes are performed.
This validates headers and linkage, not mount permissions, FUSE operations, or
SMB filesystem semantics.

## Runtime integration boundaries

The intended data path is:

```text
SMB client -> Samba -> nas-fs FUSE/VFS adapter -> Linux CIFS -> NAS
```

- Samba remains a separate server, not a Zig-linked SMB library. Its `ctdb/`,
  `source3/modules/`, `source3/include/vfs.h`, and `docs-xml/` are available for
  clustered locking and VFS integration work. VFS modules must be built for the
  selected Samba version. CTDB alone does not make a custom filesystem coherent.
- libfuse's low-level API is the initial candidate because it uses inode identities
  and explicit replies. Samba share modes, leases, and cache invalidation still
  require a cross-node prototype; FUSE alone is not an SMB clustering solution.
- cifs-utils supplies userspace tools, **not** the CIFS implementation. The running
  Linux kernel must provide CIFS/SMB support. Normal deployment can use maintained
  distribution packages for Samba and cifs-utils; source pins are also available
  for reproducible packaging and integration development.
- No extra libsmb2/libsmbclient dependency is added: the selected backend is the
  kernel CIFS filesystem. A userspace SMB client can be evaluated if kernel mount
  constraints become a blocker.
- No Linux kernel tree or separate CTDB repository is vendored.

## Zig dependency integration

The application imports raftz through `b.dependency` and a path dependency on
`third_party/raftz`. Its grpc-lite module is supplied by raftz's pinned transitive
dependency, preserving the upstream package hash. The grpc-lite submodule is the
matching source reference; it is not a second module instance in the build graph.
When adding application RPC endpoints, reuse raftz's grpc-lite dependency instance
rather than creating incompatible duplicate module instances.

The selected raftz revision pins the selected grpc-lite revision. Introduce a
RocksDB binding directly when implementing the metadata store.
Similarly, nghttp2, libxev, c-ares, and protobuf dependencies remain managed by
grpc-lite's own build rather than duplicated here.

Follow each project's build/fetch instructions when compiling it. Preserve
dependency hash verification and never patch shared package caches.

## Updating and licenses

Fetch and check out an explicit upstream tag or commit inside the relevant
submodule, review the changes and compatibility, then stage its gitlink in the
parent repository. Keep grpc-lite and raftz pins aligned when
updating their shared runtime. Run the checks and libfuse probe before committing.

Submodules retain upstream license files. Samba and cifs-utils include GPLv3
license text; libfuse's library/headers use LGPL 2.1 while other parts use GPLv2.
Consult each project's license and individual file headers for exact terms,
including transitive components. This repository does not relicense them.

Official references:

- https://www.samba.org/samba/download/
- https://www.samba.org/samba/docs/current/man-html/vfs_full_audit.8.html
- https://libfuse.github.io/doxygen/fuse__lowlevel_8h.html
- https://man7.org/linux/man-pages/man8/mount.cifs.8.html
