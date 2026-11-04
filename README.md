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
Membership changes, TLS/authentication, and
production load/partition testing remain pending. The current network service
is a cleartext prototype for trusted development networks.

Replica counts are desired metadata only. No file contents, write leases, physical
replicas, repairs, SMB exports, or FUSE operations are implemented yet. Metadata
deletion is not a physical-object garbage collection protocol.

The reference implementation uses arrays; LMDB uses indexed named databases.
Both retain prototype bounds: 4,096 live
inodes (including root) and 8,192 retained request receipts. Receipts are not
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
3. SMB/FUSE share-mode prototype, followed by NAS data placement and strict
   two-replica publication.

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
