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
The state machine is in memory and does not advertise `durable_applied` support.
Snapshots are serialized buffers; disk persistence, RocksDB, a running Raft group,
network RPC endpoints, linearizable read routing, and process recovery are pending.
The deterministic replay tests do not constitute a network consensus test.

Replica counts are desired metadata only. No file contents, write leases, physical
replicas, repairs, SMB exports, or FUSE operations are implemented yet. Metadata
deletion is not a physical-object garbage collection protocol.

The initial implementation uses bounded arrays and linear searches: 4,096 live
inodes (including root) and 8,192 retained request receipts. Receipts are not
silently evicted; at the receipt limit new request IDs are rejected, while known
IDs remain replayable. A durable store and an explicit deduplication retention
protocol must replace these prototype limits before deployment.

Each request ID is a nonzero `u64` unique across callers in this prototype; a
future RPC layer must allocate a suitable client/session-scoped identity.
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
apply errors and leave the logical state unchanged. A future proposal endpoint
must reject malformed input before appending it to Raft.

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

1. Durable metadata storage and atomic applied-cursor persistence.
2. Three-node Raft/RPC operation, failure recovery, and linearizable reads.
3. SMB/FUSE share-mode prototype, followed by NAS data placement and strict
   two-replica publication.
