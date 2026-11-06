# nas-fs

A distributed SMB file-service prototype for pooling heterogeneous NAS devices.
The design is documented in Chinese in `docs/design.zh-CN.md`.
Deployment and recovery commands are in `docs/operations.zh-CN.md`.
Native relocatable runtime bundles are described in `docs/package.zh-CN.md`.

## Build and run

Use Zig 0.17.0 on Linux. The native dependencies require a C/C++ toolchain, CMake,
Ninja, and Python 3. Initialize the pinned sources first:

```sh
python3 tools/deps.py init
zig build
zig build test
zig build run -- metadata-demo
```

`metadata-demo` creates a directory and a file, renames the file, changes its
desired replica count, and prints an in-memory snapshot. It does not mount a
filesystem, start a server, or access NAS data.

The Zig build imports raftz from its pinned submodule and uses raftz's existing
grpc-lite dependency instance. Zig verifies and fetches transitive packages using
their upstream manifest hashes into its normal package directory (`zig-pkg/`).
There is no ZooKeeper dependency.

For the native FUSE build/link probe, see `third_party/README.md`.

The experimental resident file core is available without FUSE:

```sh
zig-out/bin/nas-fs serve-files ENDPOINTS /absolute/backends.json /absolute/new-runtime-dir 1 2
zig build test-file-ipc
zig build test-file-ipc-cifs -Doptimize=safe
```

It exposes bounded, connection-owned Unix-socket file handles backed by the
existing dual-replica WAL engine. See `docs/file-ipc.zh-CN.md` for framing,
permissions, disconnect/restart semantics and limits. The interface also exposes
stat, component lookup, bounded directory pages and receipt-backed namespace
mutations. An experimental read-only native Samba VFS now connects directly to
this core, without FUSE:

```sh
python3 tools/build_vfs.py
zig build test-samba-vfs
zig build test-samba-vfs-cifs -Doptimize=safe
```

Use the matching source-built Samba daemon only. See `docs/samba-vfs.zh-CN.md`
for the single-user scope, synthetic attributes and unsupported operations.

To build a standalone runtime directory with the matching libfuse, helpers,
documentation, E2E scripts and SHA-256 manifest:

```sh
python3 tools/package.py /absolute/new/nas-fs-runtime
```

The parent directory must exist. Packaging uses a native Safe build with fault
injection disabled and a `$ORIGIN/../lib` library path. It does not install system
services or bundle system libraries such as glibc, liburing and libnuma. Use
`bin/nas-fs` and `bin/nas-fs-access` from the resulting directory on ABI-compatible
Linux hosts; see the package guide for relocation checks and required OS tools.

## Implemented foundation

- Stable inode IDs, root directory, create, rename, remove, and replica policy.
- Default two replicas; children capture the parent's policy on creation.
  Renames retain policies. Changing a directory policy affects future direct
  children, not existing files or subdirectory policies.
- Deterministic, case-insensitive ASCII name lookup with UTF-8 validation.
- Non-overwriting atomic rename, cycle prevention, and nonempty-directory checks.
- Request deduplication, including failed operations and conflicting ID reuse.
- raftz `StateMachine` adapter with owned responses and bounded streaming restore.
- Versioned snapshots that include the namespace, request receipts, inode counter,
  and applied cursor. Restore validates the tree before replacing live state.
- Allocation-failure tests for atomic apply and restore.

## Current boundaries

This is the first part of milestone M0, not a usable distributed filesystem.
The reference state machine remains in memory. The LMDB `Store` implements
`durable_applied`, synchronous transactional persistence, and logical snapshot
restore. A fixed three-voter Raft group now runs over grpc-lite with persistent
WAL, automatic snapshots, leader-only proposals, and ReadIndex-protected reads.
Real-process tests cover failover, catch-up, full restart and metadata rebuild.
An optional FUSE adapter supports lookup, attributes, directory handles,
version-pinned reads and opt-in synchronous dual-replica writes. Membership changes, TLS/authentication, and
production load/partition testing remain pending. The current network service
is a cleartext prototype for trusted development networks.

The CLI can copy, verify and publish whole files on configured mounted backend
directories, and export a verified replica. Write leases, automatic placement,
automatic repairs and cross-node SMB coordination remain pending. Missing declared
replicas can be restored manually with `repair-file`. A single-user Samba helper
supports read-only exports by default and an opt-in writable prototype.
Metadata deletion is not a physical-object garbage collection protocol. Raw `apply` publication
still validates metadata declarations only.

The reference implementation uses arrays; LMDB uses indexed named databases.
Both retain prototype bounds: 4,096 live
inodes (including root), 64 backends, 2,048 retained file versions, and 8,192
retained request receipts. Receipts are not
silently evicted; at the receipt limit new request IDs are rejected, while known
IDs remain replayable. An explicit deduplication retention protocol and capacity
planning must replace these prototype limits before deployment.

Each request ID is a nonzero `u64` unique across callers in this prototype; a
future client/session identity protocol must allocate suitable request IDs.
Snapshots retain receipts even if the referenced file has since been deleted.

Names are valid UTF-8, at most 255 bytes, and cannot contain NUL or either path
separator. Empty names, `.` and `..` are rejected. ASCII case folding is an initial
policy, **not** complete Windows/Unicode filename compatibility. Overwrite rename,
permissions, timestamps, and SMB handle/share-mode semantics remain pending.

## State-machine protocol

Normal nonempty Raft entries contain UTF-8 JSON, limited to 4 KiB:

```json
{"version":1,"request_id":1,"command":{"create":{"parent":1,"name":"photos","kind":"directory"}}}
```

Commands are `create`, `rename`, `remove`, and `set_replicas`; see
`src/metadata.zig` for their typed fields. Replicas are `"one"` or `"two"`.
The root inode is 1. Request hashes use the parsed request's canonical typed JSON,
so insignificant whitespace and omitted defaults do not change identity.

Business failures are response statuses, not terminal Raft apply errors. Malformed
committed payloads, invalid entry cursors, and allocation failures are terminal
apply errors and leave the logical state unchanged. The proposal endpoint rejects
malformed JSON, unsupported versions, zero request IDs and oversized commands
before appending them to Raft.

Responses have a fixed ten-byte prototype encoding: version byte (1), status byte
(`metadata.Status`), and an eight-byte little-endian inode ID. Allocating the
response before mutation ensures that response allocation cannot fail after a
successful state change. Empty normal entries only advance the applied cursor.

Snapshots use JSON format version 1, are capped at 8 MiB, and carry their cursor
inside the payload as well as in Raft snapshot metadata. Configuration entries
are managed by raftz, so application entry indexes may have gaps. Snapshot callers
must supply a fully applied Raft cursor. The owner must serialize state-machine
access with reads and snapshot creation; the in-memory type has no internal lock.

## Next milestones

1. Durable metadata storage and atomic applied-cursor persistence (implemented).
2. Three-node Raft/RPC operation, failure recovery, and linearizable reads (implemented).
3. SMB/FUSE operations and synchronous dual-replica publication (opt-in prototype).
4. MVP hardening: deployment and client acceptance, with guarded backend mounts
   and corrupt-replica recovery implemented.
   Tracker: https://kaneo.nuke.fuis.space/default/task/NASFS-1
5. Cross-node SMB locking, automatic placement/repair and coordinated GC.

## Local LMDB storage

LMDB 0.9.36 is compiled from the pinned source submodule. Store each node's
database on local SSD, never on an SMB share. Default synchronous commits are
used; no `NOSYNC`, `NOMETASYNC`, `MAPASYNC`, or `WRITEMAP` flags are enabled.
Each command atomically persists inode/directory updates, its request receipt,
and the applied index/term. Storage failures abort the transaction and are fatal
to the Raft adapter. Returned node names are caller-owned.

```sh
mkdir -p metadata-local
zig build run -- metadata-apply metadata-local 1 1 '{"request_id":1,"command":{"create":{"parent":1,"name":"photos","kind":"directory"}}}'
zig build run -- metadata-show metadata-local
```

These are local development tools, not Raft proposals; use a separate test
database. The directory must exist. `metadata-show` initializes an empty store
when needed. CLI map size is 256 MiB; the library requires an explicit size.
Automatic map resizing and receipt expiry are not implemented. A full map
rolls back the complete operation.

Named databases are `meta`, `inodes`, `dirents`, and `requests`. Logical snapshots
share format version 1 with the reference machine. Restore validates the bounded
image, replaces records, rebuilds directory indexes, and commits the new cursor
in one transaction. It requires enough map space for copy-on-write replacement.
Keep one environment handle per database per process, serialize state-machine
operations, and close it only after all users have stopped. NAS/RPC work must
remain outside database transactions. Tests cover reopen, reference parity,
snapshot replacement, map exhaustion, and allocation-failure rollback.
Run `python3 tools/test_lmdb_recovery.py` after `zig build` for repeated process
restart/SIGKILL checks. This checks transaction consistency and acknowledged
commits across process death, not hardware power-loss durability.

## Three-node development cluster

The CLI uses pinned zli v6.0.0. Run `nas-fs --help` or `nas-fs serve --help`.
Start each of the following in a separate terminal (replace paths as needed):

```sh
zig-out/bin/nas-fs serve --node-id 1 --cluster-id 0123456789abcdef0123456789abcdef --raft-listen 127.0.0.1:9001 --api-listen 127.0.0.1:8001 --data-dir ./node-1 --peers 1=127.0.0.1:9001,2=127.0.0.1:9002,3=127.0.0.1:9003
zig-out/bin/nas-fs serve --node-id 2 --cluster-id 0123456789abcdef0123456789abcdef --raft-listen 127.0.0.1:9002 --api-listen 127.0.0.1:8002 --data-dir ./node-2 --peers 1=127.0.0.1:9001,2=127.0.0.1:9002,3=127.0.0.1:9003
zig-out/bin/nas-fs serve --node-id 3 --cluster-id 0123456789abcdef0123456789abcdef --raft-listen 127.0.0.1:9003 --api-listen 127.0.0.1:8003 --data-dir ./node-3 --peers 1=127.0.0.1:9001,2=127.0.0.1:9002,3=127.0.0.1:9003
```

Use the same nonzero 32-hex-digit cluster ID and three distinct peer IDs/IPv4
addresses on all nodes. The local peer address must equal `--raft-listen`.
Data directory parents must exist; each node creates its own directory. For
separate machines, use their reachable IPv4 addresses. API ports are separate
from Raft ports. Peers are the bootstrap membership; restarting reuses durable
membership, and changing this flag does not reconfigure an existing cluster.

```sh
zig-out/bin/nas-fs status 127.0.0.1:8001
zig-out/bin/nas-fs status 127.0.0.1:8002
zig-out/bin/nas-fs status 127.0.0.1:8003
# Use the API endpoint whose role is "leader":
zig-out/bin/nas-fs apply 127.0.0.1:8001 '{"request_id":1,"command":{"create":{"parent":1,"name":"photos","kind":"directory"}}}'
zig-out/bin/nas-fs get 127.0.0.1:8001 2
```

`status` is a local diagnostic, not a linearizable read. `apply` returns a JSON
business result; `get` returns a node or `null`. Followers reject these operations
with `NotLeader`; a single-endpoint invocation does not retry. A transport or
timeout error may have an unknown commit outcome: find the current leader and
retry the **same request ID and command**. Without a majority, no successful write
or ReadIndex response is issued. SIGINT/SIGTERM drain the API and stop Raft.

The API is declared in `proto/metadata.proto`: unary `Apply`, `Get`, `Lookup`, `List`, and `Status`
carry bounded version-1 JSON in an `Envelope.json` bytes field. Apply uses the
request above; Get uses `{"id":2}`; Status uses `{}`. The prototype envelope codec
accepts a single field (or an empty default envelope), not arbitrary extra fields.
The internal ten-byte Raft response is converted to JSON for clients.

### Directory reads and client failover

```sh
zig-out/bin/nas-fs lookup 127.0.0.1:8001,127.0.0.1:8002,127.0.0.1:8003 1 photos
zig-out/bin/nas-fs list 127.0.0.1:8001,127.0.0.1:8002,127.0.0.1:8003 1 --limit 8
# Continue with the returned non-null `next` value:
zig-out/bin/nas-fs list 127.0.0.1:8001,127.0.0.1:8002,127.0.0.1:8003 1 --limit 8 --after photos
```

`apply`, `get`, `lookup`, and `list` accept up to three comma-separated API
endpoints belonging to the same cluster. Multiple endpoints enable leader probing
and retry: five ordered rounds, a one-second pause between rounds, and an
eight-second RPC deadline per attempt. Connection establishment also depends on
the transport/OS timeout; this is an attempt bound, not a total wall-clock deadline.
Connection failures, unavailable/deadline/backpressure statuses and leader changes
are retried. Invalid requests and other application errors stop immediately.
Every write retry uses identical JSON, including its request ID. Exhausting
retries leaves the commit outcome uncertain. `status` still accepts one endpoint.

Lookup takes `{"parent":1,"name":"photos"}` and returns a node or `null`.
List takes `{"parent":1,"limit":16,"after":null}` and returns
`{"entries":[...],"next":null}`. Both use ReadIndex and one LMDB read transaction.
A missing parent or non-directory parent is an RPC error. Names use the existing
ASCII-case-insensitive lookup rules. Pages contain 1–16 entries at most, ordered
by case-folded UTF-8 name bytes; `next` is an exclusive name cursor, or `null` at
the end. Empty directories return an empty page. Each page is independently
consistent; concurrent inserts/removes/renames between pages may omit or repeat
entries. Restart enumeration when a fresh full view is needed.

The envelope JSON limit is 32 KiB to accommodate 16 maximally escaped names;
incoming requests and replicated commands retain their 4 KiB limit. Page results
own their names and remain valid after the LMDB transaction ends.

### Read-only FUSE namespace

Build the pinned libfuse source locally, then enable the optional adapter:

```sh
python3 tools/deps.py build-fuse
zig build -Dfuse=true
mkdir -p ./mountpoint
zig-out/bin/nas-fs mount 127.0.0.1:8001,127.0.0.1:8002,127.0.0.1:8003 ./mountpoint
```

`mount` runs in the foreground; use SIGINT/SIGTERM or `fusermount3 -u ./mountpoint`
to unmount. It requires `/dev/fuse` and a working system `fusermount3` helper.
The binary links the locally built libfuse and records its build directory as a
runtime library path. The default build does not require libfuse and omits `mount`.

Directories have mode 0555, files 0444, and ownership is the mounting user's UID/GID.
Published file sizes come from immutable version metadata; timestamps remain zero.
Add `--backends backends.json` to enable read-only contents using the same local
mapping as `put-file`/`get-file`:

```sh
zig-out/bin/nas-fs mount "$ENDPOINTS" ./mountpoint --backends backends.json
```

Each open pins the queried version and fully verifies a replica's size/SHA-256
before returning its descriptor. Missing, unreadable or corrupt replicas are
skipped. Offset reads use that descriptor and the pinned size, including after
publication of a newer version or metadata unlink. New opens observe current
metadata. `direct_io` avoids sharing inode page-cache contents between different
versions. File attributes requested without a handle describe the current version,
not necessarily the version held by an older descriptor.

Without `--backends`, content opens return `EOPNOTSUPP`. With a mapping, unpublished
files return `ENODATA`, and no healthy replica returns `EIO`; a published empty file
is readable. Mutations are rejected in the default read-only mode. Reads after open do not rehash each range or
automatically switch replicas: backend read errors/premature EOF return `EIO`.
Installed objects must remain immutable; same-size out-of-band changes after open
are not detected. A read-only SMB export is available through the helper below.

Lookup and getattr use the remote linearizable metadata queries with zero entry
and attribute cache timeouts. Each opendir gathers pages into an owned list and
adds `.`/`..`; readdir offsets index that list, so rewind/resume and subsequent
metadata changes do not shift an open handle's entries. Reopen to refresh the
listing. Collection itself uses independent pages, not a global snapshot; a
detected duplicate inode or capacity overflow returns `EAGAIN`. Other concurrent
changes can still produce omissions. Up to 64 combined file/directory handles are
allowed; each directory list is bounded by the metadata inode limit. Handles and
object descriptors are freed on close or unmount.

The adapter uses libfuse's single-threaded loop. Slow RPCs, whole-file verification
on open and backend reads can stall other filesystem operations. Multi-address
retries retain their documented attempt bounds; NAS I/O has no deadline. Read
buffers are capped at 1 MiB; no mmap or SMB share-mode semantics are provided.

```sh
zig build test-fuse -Dfuse=true
```

This extends the real three-node test with two temporary FUSE mounts, multi-page
enumeration, open-handle stability during rename, cross-mount visibility,
verified contents, offset/EOF reads, pinned versions, corruption/unavailable-root
fallback, empty/unpublished files, leader failover and clean unmount. It requires
working mount permissions and fails rather than silently skipping mount checks.

### Backend and immutable version metadata

Register each backend with a nonzero numeric ID and a physical NAS failure-domain
ID. IDs and registrations are immutable; multiple shares on one NAS must use the
same domain. Backend records do not yet contain mount paths or credentials.

```sh
zig-out/bin/nas-fs apply "$ENDPOINTS" '{"request_id":101,"command":{"register_backend":{"id":1,"failure_domain":10}}}'
zig-out/bin/nas-fs apply "$ENDPOINTS" '{"request_id":102,"command":{"register_backend":{"id":2,"failure_domain":20}}}'
zig-out/bin/nas-fs backend "$ENDPOINTS" 1
```

For an existing file inode 2, publish a version with this request shape (the hash
below is illustrative):

```json
{"request_id":103,"command":{"publish":{"expected_version":0,"version":{"id":10,"inode":2,"size":123,"sha256":[7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],"backends":[1,2]}}}}
```

`expected_version` must equal the inode's `current_version` (initially zero).
Version IDs are globally unique, nonzero and never reused. Size is limited to
signed 64-bit range; SHA-256 is serialized as 32 numeric bytes. Two replicas must
reference registered backends in distinct domains; one replica uses `[ID,0]`.
The replica count must match the file's current policy. Changing policy does not
rewrite existing versions or copy data.

`file-version ENDPOINTS ID` and `backend ENDPOINTS ID` use ReadIndex-protected
queries and return `null` for missing records. `get` exposes `current_version`.
Concurrent publishers against the same old version yield one success and a
`version_conflict`; retries must reuse the original request ID and payload.
Publication atomically stores the version, inode pointer, receipt and applied
cursor. Historical versions survive replacement and inode deletion; there is no
version garbage collection yet.

Raw `apply` checks validate metadata declarations only: no NAS copies, checksums,
flushes or write-session fencing are performed. A successful publication is not
proof of physical file durability. FUSE content opens independently verify a replica.

Opening a schema-1/2 LMDB store transactionally upgrades it to schema 3, preserving
`backends`, `versions` and existing receipts. Snapshots now emit version 3;
version-1/2 snapshots remain readable, with absent `mutable_file` defaulting to
null. Legacy namespace/publication request digests remain unchanged. Downgrade
and mixed-version cluster operation are not supported; upgrade all nodes before
issuing the new commands.

The new `mutable_file.attach` metadata transition binds a prepared WAL-backed file
generation and its two backends using `expected_version` CAS. It clears the current
immutable-version pointer but retains historical objects/versions. Subsequent
`mutable_file.checkpoint` requests compare generation and `expected_sequence`,
then record the durable `next_sequence` and size without allocating an immutable
version. Sequence rollback and changing size without advancing the sequence are
rejected. Original request IDs still replay their original receipts.

These are metadata declarations, not migration or data-recovery commands. The
caller must establish exclusive ownership and durable backend checkpoints first.
Existing FUSE/object commands reject mutable-file content access until the new
access path is integrated; raw attachment therefore does not make a file usable
through SMB. See design section 42 for the protocol and validation evidence.

### Whole-file object I/O on mounted backends

After registering backend IDs and configuring mappings, initialize each existing
backend root without uploading a placeholder file:

```sh
zig-out/bin/nas-fs init-backend "$EP" backends.json 1
zig-out/bin/nas-fs init-backend "$EP" backends.json 2
```

The command checks registration and mount identity, creates and syncs `import`,
`staging`, and `objects`, and returns the registered failure domain. Repeating it
preserves existing objects and metadata. The root must already exist; failure can
leave partially created directories and retry is supported. This is initialization,
not a complete object-health scan or a multi-backend transaction.

Provide an access-node-local JSON configuration mapping registered backend IDs to
absolute, existing directories on mounted NAS shares. Paths and mount credentials
are not replicated in Raft. For local development, ordinary directories work too:

```json
[
  {"id":1,"root":"/mnt/nas-a/nas-fs","mount":{"mountpoint":"/mnt/nas-a","source":"//192.0.2.10/data","address":"192.0.2.10"}},
  {"id":2,"root":"/mnt/nas-b/nas-fs","mount":{"mountpoint":"/mnt/nas-b","source":"//192.0.2.11/data","address":"192.0.2.11"}}
]
```

Every mapping must specify either `mount` or `"allow_local":true`, never both.
Legacy entries containing only `id`/`root` now fail with `BackendIdentityRequired`.
For NAS deployments, copy the mountpoint, exact UNC source and `addr=` from
`/proc/self/mountinfo` into `mount`. Only CIFS whole-share mounts are accepted;
bind-mounted subtrees are rejected. The root must already exist. Local directory
tests may explicitly use `{"id":1,"root":"/absolute/test-root","allow_local":true}`;
this bypasses mount identity checks and does not establish a physical NAS replica.

The adapter opens the root first and uses its descriptor's `mnt_id` to locate
the active CIFS mount. It validates the expected mountpoint, source and address
before initializing any directories. `staging` and `objects` must belong to the
same mount as the root. Upload, repair, verified reads and FUSE/SMB all use this
path; object installation rechecks the root before copying and before installing.
Wrong/absent/detached mounts fail with `BackendMountMismatch`; reads can try the
other replica. A fresh correct remount is accepted without changing configuration.
Pinned descriptors cannot fall through to newly exposed local storage; in-flight
I/O can still finish against the original filesystem if detachment races a check.

Duplicate share names at the same configured server address are rejected even
when the UNC hostname or local paths differ. Linux mountinfo does not expose the
CIFS TCP port, so different ports do not make otherwise identical identities
distinct. Physical NAS failure domains remain administrator declarations: aliases,
multiple shares or addresses do not prove independent hardware. Mount identity
validation is not NAS authentication or a distributed fencing protocol.

Create the file inode and register backends first, then upload a stable source:

```sh
zig-out/bin/nas-fs put-file "$ENDPOINTS" backends.json \
  '{"request_id":104,"inode":2,"version_id":11,"expected_version":0,"backends":[1,2]}' ./photo.jpg
zig-out/bin/nas-fs get-file "$ENDPOINTS" backends.json 2 ./download.jpg
```

Adjust `expected_version` to the inode's actual current version. Use `[1,0]` for
a file with policy `one`. New request/version IDs must be globally unique;
retry an uncertain upload with the same JSON and unchanged source file.

`put-file` hashes the source, checks metadata policy, then initializes `import/`,
`staging/` and `objects/` under the configured roots. It copies in 256 KiB chunks
to exclusive random staging names, checks size and SHA-256, fsyncs and reads back
each file, and atomically renames without replacing existing objects. Object names
are `<decimal-version-id>-<lowercase-sha256>`. Including the digest isolates
competing uploads that accidentally reuse a version ID with different contents.
Both rename directories are synced before the metadata CAS is submitted. Existing
objects are verified and synced rather than overwritten. Any required replica
failure prevents publication; there is no automatic downgrade to one replica.

As with `apply`, a submitted metadata result is JSON: check `status == "ok"`.
Local I/O/preflight failures exit nonzero; a CAS race can return a non-`ok` JSON
result. A replay of an already-published identical version submits the original
metadata request again; it does not repair lost replicas. After an uncertain RPC
result, retain all installed objects and retry the same request.

`get-file` pins the current version observed by a linearizable inode query,
then tries its configured replicas in order. Missing/unreadable or checksum-invalid
replicas are skipped during verification. Export uses a temporary file in the
destination directory, checks the hash again, syncs and renames without replacing
an existing destination. Source failure during the export itself fails the command;
rerun to select a replica again. Partial exports are cleaned up on normal errors.

Check every declared replica of a file's current version:

```sh
zig-out/bin/nas-fs check-file "$ENDPOINTS" backends.json 2
```

The JSON report contains `inode`, pinned `version`, `size`, `healthy_replicas`,
`all_healthy`, and `replicas` with each backend's `status` and nullable `reason`.
Statuses are `healthy` (full size/SHA-256 verification), `missing` (object absent
in an opened store), `corrupt` (size/hash mismatch), `unavailable` (store/read
failure or an unstable/invalid object), and `unconfigured` (no local mapping).
`reason` is the underlying error name. Every declared replica is checked, even
after finding a healthy one. Single-replica versions produce one result.

A completed scan exits successfully even when replicas are unhealthy; automation
must inspect the JSON. Invalid configuration, metadata failures, directories and
unpublished files fail the command. `all_healthy` covers the version's declared
replicas, not compliance with a subsequently changed desired replica policy.
The scan does not modify metadata or object contents, initialize roots, or repair
replicas. Results describe sequential observations of one pinned version, not an
atomic health snapshot; concurrent publication can make that version historical.
Full-file hashing is synchronous and has no NAS I/O deadline.

Restore a missing object on an already-declared backend:

```sh
zig-out/bin/nas-fs repair-file "$ENDPOINTS" backends.json 2 1
```

The last arguments are the inode and destination backend ID. The command pins
the observed current version and requires an existing backend store. It selects
a fully verified other replica, copies through staging, checks and reads back the
bytes, syncs, then atomically installs without replacing an existing object.
Concurrent repairs converge on a verified object. No metadata update is needed.
The JSON result includes `inode`, `version`, `backend`, `source_backend` and
`status`: `repaired`, or `already_healthy` with a null source when no copy is needed.
The already-healthy path still syncs the object and both directories, completing
durability work that an interrupted earlier repair may not have finished.
`repaired` can include another concurrent repair winning the installation race.

Missing mappings/stores, undeclared destinations and absence of a healthy source
fail the command. Corrupt existing objects are rejected by default. The command
does not initialize directories or add replica
locations. A failure after installation may leave a valid object; retrying is
safe. Concurrent publication/deletion can make the pinned version historical,
but repair never republishes it or recreates namespace entries. Retry after
checking the reported version if the current file changed. Automatic repair and coordination with future
garbage collection remain pending.

To explicitly restore a checksum-invalid object on the selected backend:

```sh
zig-out/bin/nas-fs repair-file "$ENDPOINTS" backends.json 2 1 --replace-corrupt
zig-out/bin/nas-fs check-file "$ENDPOINTS" backends.json 2
```

`--replace-corrupt` enables atomic replacement after the source and staged copy
have passed full size/SHA-256 verification, file sync and readback. The target is
rechecked after staging: an already healthy object is kept; only a checksum
mismatch permits replacing the object name. Other errors fail without replacing
it. The installed and staging directories are synced before success. The flag
also retains normal missing-object repair behavior. Uploads and SMB writes never
enable replacement.

Concurrent repairs install equivalent bytes for the same immutable version.
Replacement does not rewrite the old inode: existing readers retain their old
descriptor, including its corruption/errors, while new opens use the repaired
copy. Reopen a failed read after repair. Metadata, version IDs and namespace
entries do not change. No bad-object archive is retained. Installed objects may
remain after an uncertain failure; retry and check their health. This does not
provide physical NAS power-loss guarantees or coordinate with out-of-band writers.

Repair fault tests use an explicitly instrumented build:

```sh
zig build test-cluster -Dfault-injection=true
zig build test-e2e -Dfault-injection=true -Doptimize=safe
```

The harness pauses a repair at verified checkpoints, observes `SIGSTOP`, then
kills it before replacement, after replacement, or after directory sync. It
verifies retry, orphan staging behavior and unchanged metadata. It also pauses
repair while publishing a newer version, deleting/reusing the inode's name, or
installing a concurrent healthy replacement. Normal builds compile out these
checkpoints and ignore `NAS_FS_REPAIR_STOP`. Only test builds interpret its values
`before_replace`, `after_replace`, and `after_sync`; do not deploy an instrumented
binary. The fault tests simulate process death, not NAS hardware power failure.

Writable FUSE and SMB crash acceptance uses the same instrumented build:

```sh
zig build test-smb -Dfuse=true -Dfault-injection=true -Doptimize=safe
```

For both direct FUSE writes and SMB uploads, the harness kills the access process
after the first replica, after both replicas, and after metadata publication but
before replying. It checks the exact installed objects, committed metadata,
client failure, read-only visibility, and successful writes after restart.
Pre-publication crashes preserve the previous committed contents, including for
SMB overwrite; its truncation remains in backend staging until publication.
Post-publication crashes expose the new contents despite client failure.
An additional case kills `smbclient` after the first replica and resumes the access
process: the in-flight write still commits two healthy replicas without a client
acknowledgement. Disconnect does not cancel or roll back an accepted write;
reopen and inspect the committed state before deciding whether to retry.
Only instrumented builds honor `NAS_FS_WRITE_STOP` values `first_stage_write`,
`first_replica`, `both_replicas`, and `published`, for nonempty writes/publications. Normal builds
omit these checkpoints. This coverage uses Linux clients; Windows/macOS client
acceptance and distributed SMB locking remain outstanding.

The fault suite also pauses FUSE and SMB requests after both replicas are installed
but before the metadata RPC, kills the current metadata leader, waits for a new
leader, and resumes the request. It verifies that metadata remained unchanged
during the pause, the client succeeds, and exactly the staged version becomes
current with two healthy replicas. The old voter is restarted and the access-node
restart/write checks run afterward. Both Debug (omit `-Doptimize=safe`) and Safe
full fault suites pass. This case covers leader change before the publication RPC,
not election during an in-flight Raft commit or a lost commit reply.

Two more cases stop both metadata followers after object installation, resume the
FUSE/SMB request, and keep quorum unavailable until the client reports failure.
Only then are the voters restarted. Recovery accepts either the previous version
or the exact staged version, checks the corresponding contents and two healthy
replicas, and verifies further writes after access restart. A timed-out proposal
may commit once quorum returns; the direct FUSE cases observed this delayed commit
in both Debug and Safe runs. Object installation alone never warrants a successful
commit acknowledgement. These cases bring the fault matrix to eleven scenarios.

Two metadata-reply-loss cases extend this matrix to thirteen scenarios. After a
nonempty publication commits, a one-shot server checkpoint stops the leader before
its RPC reply. The harness kills it, waits for a different leader, and replays the
exact original request ID and publication. The new leader must return the original
successful receipt despite its now-stale `expected_version`, without changing the
published version. FUSE/SMB contents, two healthy replicas and writable restart
are checked afterward. Automatic client retries remain bounded and can return
failure during election; receipt replay and committed-state recovery are verified
even in that case. This does not make ordinary client reopen/rewrite reuse the
original request ID or guarantee transparent SMB session recovery.

Two backend-staging crash cases bring the total to fifteen: kill FUSE between the
two staging writes, or after both staging writes were acknowledged but before
fsync. Neither changes installed objects or committed metadata; restart reads the
previous version. Ordinary `WRITE_ACK` is distinct from durable `COMMIT_ACK`.

Only instrumented metadata servers read `NAS_FS_PUBLISH_STOP_DIR`: an inode-named
marker in this directory arms the next successful nonempty publication's reply
checkpoint. The server consumes the marker before stopping so replay on another
voter does not stop again. Normal builds omit this selector and checkpoint.
Debug and Safe complete SMB fault suites pass. FUSE publication failures now log
the inode, expected version and error name to aid uncertain-outcome diagnosis.

Operational boundaries:
- Roots and their parent paths must be administrator-controlled. Root and object
  symlinks are rejected; duplicate configured IDs/paths and identical canonical
  upload roots are rejected. Guarded mappings verify CIFS mount presence and identity;
  physical failure domains remain administrator-configured. Two local directories
  are not physical replicas.
- `staging/` and `objects/` must share a filesystem supporting atomic no-replace
  rename and file/directory fsync. Unsupported operations fail the upload. CIFS
  transport is covered by the Samba E2E below; NAS power-loss durability remains
  unverified. Readback can hit the client cache, and fsync relies on the server's
  persistence contract.
- Keep source files stable during upload and protect installed objects from direct
  modification. Size/timestamp changes and digest mismatches are detected, but
  this is not a filesystem snapshot or a write-session fencing protocol.
- Failed/conflicting uploads can leave unreferenced installed objects; SIGKILL can
  also leave staging/export temporary files. No automatic cleanup or GC is safe
  yet because an uncertain RPC may have committed.
- I/O is synchronous, with bounded memory but no NAS-operation deadline, resume,
  space reservation, automatic import or background repair. Existing metadata
  client retry bounds can expire during prolonged/split elections; retry afterward.

`zig build test-cluster` now also verifies real local-directory copies, failed
second-replica publication, retries, per-replica health reports, corruption/unavailable-replica fallback,
non-overwriting exports, empty/single-replica files, concurrent publishers and
whole-cluster restart. These tests do not emulate NAS hardware durability.

### Real Samba/CIFS backend E2E (Linux)

```sh
zig build test-e2e
zig build test-e2e -Doptimize=safe
zig build test-e2e -Dfuse=true -Doptimize=safe
```

Requires `smbd`, `smbclient`, `mount.cifs`, `umount`, `unshare`, Python 3 and
non-interactive `sudo -n` access, plus kernel CIFS and mount-namespace support.
Run as an ordinary user. The runner starts two loopback-only Samba instances on
temporary high ports with private configuration/state and guest shares. It mounts
SMB 3.1.1 shares inside a private mount namespace (`cache=none,actimeo=0`) and drops
privileges for the three-node metadata/object suite. No existing Samba service or
system configuration is changed.

Coverage includes failed-second-replica publication, immutable retries, checksum
and unavailable-root fallback, concurrent publication, metadata failover/restart,
and independent `smbclient` downloads of both replicas. The runner then unmounts,
restarts Samba, remounts, and checks every installed object's SHA-256. The unavailable
root check renames a directory; it does not simulate an unreachable NAS or test I/O
timeouts. Server-side symlink injection checks that substituted objects cannot be read.

Successful runs stop processes, unmount shares and remove their workspace; failures
retain Samba logs and backend objects under `${TMPDIR:-/tmp/opencode}/nas-fs-e2e-*`.
Verified with Samba 4.24.7 and Linux CIFS. This covers the backend SMB transport,
not a client-facing unified SMB export or physical NAS power-loss durability.
With `-Dfuse=true`, the suite also runs two real FUSE mounts over these CIFS-backed
objects, including version-pinned reads; build libfuse and enable `/dev/fuse` first.

### Supervised access-node startup and shutdown

After mounting CIFS shares, registering/initializing backends and starting the
metadata cluster, one foreground helper can own both FUSE and Samba:

```sh
mkdir -p mountpoint
python3 tools/serve_access.py "$EP" "$PWD/mountpoint" "$PWD/access-state-01" \
  --backends "$PWD/backends.json" --port 1445
```

The default is read-only. Add `--write-backends 1,2` to enable both writable FUSE
and writable SMB; use only one writable entrance. `--executable` selects a nas-fs
binary (default `zig-out/bin/nas-fs`), and `--listen` selects the local IPv4 address
(default loopback). The mountpoint must be an existing empty directory. The helper
locks its underlying directory and refuses mounted/busy paths. The state directory
must be new and outside the mountpoint; use a short path with an existing parent.

Startup waits for FUSE before launching Samba and prints one JSON readiness record
with the child PIDs, SMB port and writable mode. This signals service startup, not
a full backend/metadata health check. SIGINT/SIGTERM stops Samba first, unmounts
FUSE and waits for the child. Either child's unexpected exit shuts down the other
and returns nonzero. The helper uses mountinfo even for disconnected FUSE mounts;
it does not automatically lazy-unmount a busy mount. Logs remain in `fuse.log` and
`s/process.log`, `s/samba.log` beneath the state directory.

Restart with the same empty mountpoint and a new state directory. The helper does
not manage metadata voters or CIFS mounts, automatically restart children, or
provide writer fencing. Killing the helper itself with SIGKILL cannot run its
cleanup; stop remaining Samba processes and unmount FUSE before restarting.
The SMB E2E covers normal stop, each child's SIGKILL, repeated mountpoint reuse,
persisted file downloads, default read-only mode and startup rejection/cleanup.

### Read-only SMB access-node prototype

Start the FUSE mount with `--backends` as above. As the same ordinary user, run:

```sh
python3 tools/serve_smb.py ./mountpoint ./smb-state --port 1445
smbclient //127.0.0.1/nas -p 1445 -N -U guest -c 'ls'
smbclient //127.0.0.1/nas -p 1445 -N -U guest -c 'get photo.jpg download.jpg'
```

`smb-state` must be a new directory; its parent must exist. The helper checks for
a nas-fs FUSE mount owned by the invoking user, validates the generated config with
`testparm`, and runs `smbd` in the foreground. SIGINT/SIGTERM stops its process group;
configuration, state and logs remain in `smb-state`. Stop Samba before unmounting
FUSE. No `allow_other` or system Samba changes are needed because Samba runs as the
mount owner. The helper requires Linux, Python 3, `smbd` and `testparm`.

The default listener is loopback. `--listen LOCAL_IPV4` explicitly binds another
local address for LAN experiments. This prototype exports `[nas]` as an anonymous,
single-user, read-only SMB3 share; all clients act as the mount owner. It does not
implement account isolation or a production authentication policy. Use `-U guest`
with the shown client commands. Clients must support the chosen port and guest
access; Windows/macOS client compatibility has not yet been tested.

SMB leases and oplocks are disabled because metadata publications bypass Samba's
local lock state; sendfile is disabled to use the verified FUSE read path. New
connections/opens read current metadata. Tests cover fresh SMB connections, not
arbitrary client cache behavior or change notifications. FUSE retains its fixed
version handles and full-file verification cost. There is no CTDB coordination,
cross-node SMB locking, durable-handle failover or complete file
timestamp/ACL model.

```sh
zig build test-smb -Dfuse=true
zig build test-smb -Dfuse=true -Doptimize=safe
```

This extends the private-namespace E2E with two independent Samba access nodes:
`smbclient → Samba → FUSE → CIFS → backend Samba`. It checks listing and file sizes,
byte-exact downloads, rejected upload/delete/rename/mkdir, same-size version
replacement, metadata rename/delete visibility, empty files, corrupt-replica
fallback, all-replicas-corrupt errors and metadata leader failover. It also runs
the existing backend restart/remount hash checks. No hardware power-loss durability
or SMB session migration is implied.

### Opt-in writable SMB prototype

Use one writable access node for this prototype. Keep other SMB entrances read-only;
there is no distributed SMB lock service or automatic writer failover. Both backend
IDs must already be registered in distinct failure domains, mapped locally, and
have existing `staging/` and `objects/` directories (initialize with `init-backend`).

```sh
zig-out/bin/nas-fs mount "$ENDPOINTS" ./mountpoint --backends backends.json --write-backends 1,2
python3 tools/serve_smb.py ./mountpoint ./smb-write-state --port 1445 --writable
smbclient //127.0.0.1/nas -p 1445 -N -U guest -c 'mkdir photos; put photo.jpg photos/photo.jpg'
```

Creating files/directories, uploading, overwriting/truncating contents, offset
writes, non-replacing rename/move, unlink and empty-directory removal are supported.
The writable mount uses modes 0755/0644 and creates new entries with policy `two`;
opening a single-replica-policy file for writing is rejected. The selected pair is
used for each new version. Existing read-only mounts and exports remain unchanged.
The helper refuses `--writable` on a read-only mount. DOS archive-bit mapping and
DOS xattr storage are disabled; ownership/mode/time changes, ACLs, links, mmap,
rename-over-existing and persistent timestamps are not implemented.

Each writable handle owns a staging file on each of the two NAS backends. Ordinary
write/truncate operations update both staging files directly, currently sequentially;
the access node uses bounded buffers, not a whole-file local temporary file.
New/truncating opens start empty; partial updates seed both stages from a verified
current replica. `flush`, `fsync`, and close synchronize and hash both stages,
install them by rename, then publish with version CAS. `O_SYNC`/`O_DSYNC` writes
publish before replying. A clean repeated fsync creates no new version.

An ordinary write acknowledgement means both stages accepted the bytes, **not**
durable metadata publication. Writable handles read their staged changes; other
readers see committed versions, and existing read handles pin their original version.
New inodes may be visible before they have readable committed contents. Subsequent
mutation after publication creates fresh stages from the committed version; installed
objects are never modified. Flush can publish during an upload (including inherited
descriptor close), so this is not whole-upload atomic replacement.

Only one writable handle per inode is allowed in a mount (`EBUSY`). External CLI
publication or another mount can cause a CAS conflict (`EAGAIN`); this prevents
stale overwrite, but does not implement cross-node SMB share modes. Any write I/O
or publication failure freezes that handle: later writes/reads/flushes fail and
close can report the error. Reopen and inspect current metadata after an uncertain
RPC result; an error can hide a committed version. Failed create can leave an
unpublished inode, and failed publications can leave installed objects. Process
death can leave orphan backend staging files; acknowledged but unpublished writes
are not recovered automatically. Installed objects are retained even on RPC errors
because publication may have committed. No automatic staging recovery/GC or durable
SMB session migration is provided.

Metadata rename/remove now resolve parent/name inside the Raft-applied transaction
(`rename_entry`/`remove_entry`), avoiding a separate lookup/mutation race. Existing
targets are never replaced, and nonempty directories cannot be removed. Upgrade
all metadata nodes together before using these new commands; older binaries do
not recognize their WAL entries.

Prototype limits still apply: 64 handles per mount, 2,048 retained versions and
8,192 request receipts, no GC, no NAS I/O deadline, and administrator-trusted mount
physical failure domains. Frequent flush/publication can exhaust the version limit
quickly. Guarded mappings reject mount mismatches; `allow_local` explicitly bypasses
that protection. This is not yet a production writable filesystem.

`test-fuse` now includes writable offset/truncate, fixed old reads, writer exclusion,
CAS conflict, second-store failure and namespace checks, plus staging visibility,
rename inode preservation, repeated fsync, same-handle multiple commits, sparse
writes, staging corruption and O_DSYNC. `test-smb` additionally
exercises real SMB upload/overwrite/download/rename/delete/mkdir/rmdir, empty files,
second-replica failure and writes after metadata leader recovery, alongside the
existing read-only tests and backend restart/remount hash checks.

### Persistence and recovery

The separate mutable-file WAL prototype now has durable checkpoints, WAL rotation,
explicit old-log collection and exclusive file ownership. It is not yet connected
to the SMB/FUSE path above. Run its real dual-CIFS process-death acceptance with:

```sh
zig build test-file-store -Doptimize=safe
```

This tests recovery after write, checkpoint and collection SIGKILL, competing
openers, stable data inodes and cold CIFS remount. See design sections 39–41 for
the planned transition and remaining metadata/read-coordination work.

The guarded access-session layer additionally migrates immutable contents into a
WAL-backed complete file, binds it through live Raft metadata, and reconciles
recovered data checkpoints before serving reads. Its integration test is:

```sh
zig build test-mutable-access -Doptimize=safe
```

This combines three voters and two CIFS backends, tests process death and leader
change, and retains historical objects. The session currently requires exclusive
ownership of both replicas and serialized local callers. See design section 43.

FUSE and the access supervisor now support opt-in `--write-mode wal`, together
with `--write-backends 1,2`. Local handles share one mutable session and observe
current contents and size; first open (including a read-only open) migrates old
immutable data. Flush/fsync/close checkpoints both replicas and Raft metadata.
The default remains `staging`. Mutable files cannot be read through staging
mounts or the immutable-object CLI. Keep one WAL access process per active file;
competing mounts are rejected, only one local writable handle is supported, and
unlink while local handles remain open returns `EBUSY`. See design section 44
and the operations guide before enabling this mode.

```sh
zig build test-wal-fuse -Dfuse=true -Doptimize=safe
zig build test-wal-smb -Dfuse=true -Doptimize=safe # real dual CIFS + SMB; sudo
```

WAL reads compare both replicas and fail/freeze the shared session on divergent
bytes or lengths. For an existing mutable file with no active access handles,
run `nas-fs scrub-mutable ENDPOINTS CONFIG INODE` to recover it and compare its
entire contents using bounded buffers. JSON reports `replicas_equal`, size,
generation, sequence and the observed SHA-256. This is replica agreement, not
verification against a trusted content digest; identical corruption remains
undetectable. Opening for maintenance may replay WAL and reconcile checkpoints.
The command never migrates immutable files or selects a repair source.

For idle files, `seal-mutable ENDPOINTS CONFIG INODE` explicitly persists a
generation/sequence-bound SHA-256 baseline after both replicas agree. Later
opens and scrubs validate it, detecting even identical subsequent corruption.
`repair-mutable ENDPOINTS CONFIG INODE` can restore an existing damaged replica
in place only when the other replica matches that valid baseline. Both data
locks remain held; an interrupted copy can be retried. Neither matching source
nor valid baseline means repair is refused.

Before the next write/truncate, both seal files are durably removed; ordinary
fsync does not rebuild a whole-file seal. Re-establish the baseline explicitly
after updates. This protects idle sealed contents, not continuously changing
data, and cannot discover damage already identical on both replicas at first
sealing. All access processes must use a seal-aware build. See design section 46
and the operations guide for lifecycle and recovery limits.

To exercise real process death during sealed repair, use the test-only build:

```sh
zig build test-wal-fuse -Dfuse=true -Dfault-injection=true
zig build test-wal-smb -Dfuse=true -Dfault-injection=true -Doptimize=safe
```

Both targets kill repair after its first 256 KiB copy and after destination
fsync, with each NAS serving as the damaged target. They check exclusive
ownership, retained source/seal/WAL/checkpoint bytes and successful in-place
retry. Normal builds ignore these stop points even if their environment
variable is set. Process-death coverage does not establish hardware-power-loss
durability.

The same fault-enabled targets also kill seal publication after one or both
copies are durable, and kill FUSE during one-sided or completed seal
invalidation before both write and truncate. They verify unchanged data/WAL,
failure of the interrupted syscall, recovery with a remaining valid seal or
without a seal, and successful mutation retry followed by resealing.

Before checkpoint rotation, WAL mode now revalidates both active logs and checks
their final effects against both data files. Overlapping writes, truncation,
regrowth and sparse zero ranges are resolved in operation order. A mismatch
freezes the session before checkpoint publication or log collection, preserving
redo evidence for reopen/recovery. This detects identical corruption within
WAL-covered ranges, not corruption in untouched baseline bytes or damage after
their WAL has been retired. It adds reads proportional to the log and covered
logical data ranges (including sparse gaps), plus memory proportional to record
count. No file-format change is required. See design section 49.

While WAL records remain active, reads now validate the actual returned buffer
against WAL evidence for that range, and stat checks the WAL-derived length.
Scrub also validates pending evidence before scanning the file. The EOF probe
checks its byte against WAL when covered, detecting CIFS zero-fill after an
out-of-band truncation of a nonzero tail. Failures freeze the shared session
without retiring recovery evidence. This conservative implementation rereads
both active logs for read/size checks; small reads can therefore be expensive
with a large pending WAL. The FUSE read callback now uses the verified actual
byte count directly, without a separate size preflight or clipping to a stale
handle size. Independent stat calls still validate size. It does not cache an
authoritative content index or protect untouched/retired baseline ranges. See
design sections 50–51.

Read/size WAL validation now streams both complete logs with fixed read-ahead,
retaining at most one 1 MiB record per replica plus a copy of the actual read
window. It no longer retains full logs or builds/sorts per-record interval
indexes for these requests. Later records overwrite the window's expected
bytes and EOF evidence; every record is still authenticated, including records
outside the request. A bounded-allocation test covers a WAL larger than 16 MiB
within 4 MiB of verification heap scratch. Checkpoint/full-scrub validation keeps
its existing interval algorithm. This reduces read-validation memory, not total
WAL bytes transferred; NAS throughput has not been benchmarked. See section 52.

An opt-in read/stat latency benchmark is available via `--wal-benchmark` in the
WAL FUSE/CIFS test harnesses, or `tools/benchmark_wal.py` on a dedicated test
mount. See `docs/benchmarks.zh-CN.md` for commands, samples and limitations.
The first same-host run found about 201 ms for 4 KiB reads even with an empty
WAL, prompting metadata/read-barrier timing investigation.

Stage tracing (`-Dlatency-trace=true`) identified the metadata ReadIndex wait.
The runtime now uses raftz's event-driven `Raftor.run()` from PR #7, pinned at
`e506a2818f610b3d3aeebb786da11378ceb391ad`; the local 1 ms poll loop is removed.
Requests, gRPC inbound messages and shutdown notify the driver, while logical
ticks remain at 100 ms. Metadata handlers now wait on callback notifications
rather than polling completion every millisecond. In untraced same-host Safe
runs, clean 4 KiB reads took about 0.51 ms locally and 2.23 ms over dual loopback
CIFS, versus 1.31/3.08 ms before this handler-side change. Large pending WALs
still dominate data-path costs; full WAL authentication remains. Faster reopening also
exposed stale CIFS WAL length: recovery now reads the actual bounded tail rather
than treating stat as authoritative EOF, while rejecting complete corruption.

The benchmark also records voter/FUSE CPU time and surviving-thread context
switches, using three five-second idle windows and at least one second per load
case. Event-driven execution reduced whole-voter voluntary switches from about
1950/s to 1010–1020/s, but measured idle CPU remained similar (roughly 0.3–0.5%
of one core per voter). Remaining switches include other process threads.
With 16 MiB pending payload, the PR-only comparison used about 95% of one
FUSE core for sustained local small reads. These counters exclude Samba/kernel CPU and do not measure power
consumption. The benchmark document records the PR pin, comparison and limits.

WAL diagnostics now split setup, header processing, payload reads, payload
comparison, record authentication, evidence overlay and final bounds checks.
Profiling identified payload comparison as the largest local cost in the tested
Safe build. Bounded 8-byte comparisons now replace the large-payload comparison
in streaming read/size verification; every byte and every record checksum is
still checked, with no cache or format change. In same-host untraced runs,
4 KiB reads with 16 MiB pending payload fell from 27.4/39.1 ms to 13.1/25.6 ms
(local/dual CIFS), with about 13 ms FUSE CPU per operation. See the benchmark
document for stage timings and portability limits.

The streaming reader now drains any prefetched bytes, then reads large remaining
payload spans directly into the existing frame buffer. Small spans retain the
64 KiB read-ahead path. This reduces user-space read calls and copies without
changing WAL transfer bytes, memory bounds or integrity checks. In the same-host
16 MiB pending-payload benchmark, small reads fell further from 13.1/25.6 ms to
12.4/17.5 ms (local/dual CIFS); actual SMB packet counts were not measured.

FUSE session acquisition now returns its freshly verified size together with the
shared session. Attribute replies and non-truncating opens reuse that result;
truncating opens verify size again after mutation. Independent requests still
revalidate. This removes one duplicate size/WAL scan from shared-session stat:
with 16 MiB pending payload, median stat latency fell from 25.0/34.1 ms to
12.6/18.8 ms (local/dual CIFS) in the same-host benchmark.

Streaming verification now reads the two payloads concurrently for records of
at least 128 KiB; smaller records keep serial read-ahead. Both reads are joined
before checking results or freeing buffers, including error paths. Exact byte,
checksum and EOF checks remain. A repeated same-host CIFS comparison measured
16 MiB-pending small reads at 21.4 ms serial versus 15.6/18.2 ms in two parallel
runs; the benchmark document preserves both runs and their variability.

Each node owns `DATA_DIR/raft/` (raftz WAL, membership, snapshots) and
`DATA_DIR/metadata/` (LMDB). Keep both on local durable storage. LMDB is bound to
the node and cluster identity; a mismatched identity fails startup. An exclusive
process lock prevents simultaneous access by another server or local CLI tool.
`metadata-show` can inspect a stopped node's metadata directory; `metadata-apply`
rejects cluster-managed stores.

Restart with the same identity, paths and addresses. raftz checks the LMDB cursor
against committed WAL state, restores a newer snapshot when necessary, and
replays committed entries after that cursor. A lagging peer can receive a remote
snapshot and continue from its log. Automatic snapshots default to every 1,000
applied entries (`--snapshot-entries 8` is useful in recovery tests).

Both filesets are needed for normal recovery: retaining only LMDB is not a Raft
backup. The integration test additionally exercises rebuilding a missing LMDB
from intact local WAL/snapshots. It does not test lost disks, power cuts, or
arbitrary storage corruption.

```sh
zig build test-cluster
```

This launches three processes on temporary loopback ports and isolated temporary
directories, kills/restarts nodes, forces snapshot catch-up, rebuilds metadata,
checks quorum loss, and verifies graceful shutdown. It requires Linux io_uring
support for grpc-lite.
