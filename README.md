# nas-fs

A distributed SMB file-service prototype for pooling heterogeneous NAS devices.
The design is documented in Chinese in `docs/design.zh-CN.md`.

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
4. MVP hardening: backend mount identity, corrupt-replica recovery, deployment and
   client acceptance. Tracker: https://kaneo.nuke.fuis.space/default/task/NASFS-1
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

Opening a schema-1 LMDB store transactionally upgrades it to schema 2 with
`backends` and `versions` databases. Snapshots now emit version 2; version-1
snapshots remain readable with empty version/backend lists and zero current
version defaults. Legacy namespace request digests remain unchanged. Downgrade
and mixed-version cluster operation are not supported; upgrade all nodes before
issuing the new commands.

### Whole-file object I/O on mounted backends

Provide an access-node-local JSON configuration mapping registered backend IDs to
absolute, existing directories on mounted NAS shares. Paths and mount credentials
are not replicated in Raft. For local development, ordinary directories work too:

```json
[{"id":1,"root":"/mnt/nas-a/nas-fs"},{"id":2,"root":"/mnt/nas-b/nas-fs"}]
```

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
checking the reported version if the current file changed. Backend mount identity
is still trusted configuration; automatic repair and coordination with future
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

Operational boundaries:
- Roots and their parent paths must be administrator-controlled. Root and object
  symlinks are rejected; duplicate configured IDs/paths and identical canonical
  upload roots are rejected. Physical NAS identity and mount presence are trusted
  configuration, not discovered: two local directories are not physical replicas.
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
have existing `staging/` and `objects/` directories (as initialized by `put-file`).

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

Each writer uses an anonymous local temporary file (`tmpfile`, closed on handle
release) seeded from a verified current replica. Each FUSE write or size change
copies the **whole resulting file** to both NAS stores, verifies/syncs/readbacks
the objects, and publishes through version CAS **before returning success**.
Create publishes a dual-replica empty version before acknowledging success.
`flush`/`fsync` report the handle's existing result, with no additional publication.
This deliberately expensive path establishes synchronous correctness, not throughput:
uploads can expose committed intermediate versions, and overwrite may first publish
an empty truncation. It is not whole-upload atomic replacement. Read handles still
pin their original versions.

Only one writable handle per inode is allowed in a mount (`EBUSY`). External CLI
publication or another mount can cause a CAS conflict (`EAGAIN`); this prevents
stale overwrite, but does not implement cross-node SMB share modes. Any write I/O
or publication failure freezes that handle: later writes/reads/flushes fail and
close can report the error. Reopen and inspect current metadata after an uncertain
RPC result; an error can hide a committed version. Failed create can leave an
unpublished inode, and failed publications can leave objects; neither is reported
as a successful write or automatically deleted. Process death closes local staging,
and previously acknowledged writes remain published. No unacknowledged staging
recovery or durable SMB session migration is provided.

Metadata rename/remove now resolve parent/name inside the Raft-applied transaction
(`rename_entry`/`remove_entry`), avoiding a separate lookup/mutation race. Existing
targets are never replaced, and nonempty directories cannot be removed. Upgrade
all metadata nodes together before using these new commands; older binaries do
not recognize their WAL entries.

Prototype limits still apply: 64 handles per mount, 2,048 retained versions and
8,192 request receipts, no GC, no NAS I/O deadline, and administrator-trusted mount
identity. Per-write publication can exhaust the version limit quickly. NASFS-5
tracks mount identity checks; this is not yet a production writable filesystem.

`test-fuse` now includes writable offset/truncate, fixed old reads, writer exclusion,
CAS conflict, second-store failure and namespace checks. `test-smb` additionally
exercises real SMB upload/overwrite/download/rename/delete/mkdir/rmdir, empty files,
second-replica failure and writes after metadata leader recovery, alongside the
existing read-only tests and backend restart/remount hash checks.

### Persistence and recovery

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
