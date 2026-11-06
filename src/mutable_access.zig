//! Single-owner mutable file access. Callers serialize operations and share one
//! session among local handles. No lease expiry, automatic failover or hidden GC.
const std = @import("std");
const m = @import("metadata.zig");
const objects = @import("objects.zig");
const files = @import("file_store.zig");
const mount = @import("backend_mount.zig");
const Io = std.Io;
const Dir = Io.Dir;

/// Value-only metadata view; no borrowed inode names cross the interface.
pub const Head = struct {
    id: u64,
    kind: m.Kind,
    replicas: m.Replicas,
    current_version: u64,
    mutable_file: ?m.MutableFile,

    pub fn from(node: m.Node) Head {
        return .{ .id = node.id, .kind = node.kind, .replicas = node.replicas, .current_version = node.current_version, .mutable_file = node.mutable_file };
    }
};

pub const Metadata = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, u64) anyerror!Head,
    version: *const fn (*anyopaque, u64) anyerror!m.Version,
    backend: *const fn (*anyopaque, u64) anyerror!m.Backend,
    apply: *const fn (*anyopaque, m.Request) anyerror!m.Result,
};

pub const Access = struct {
    io: Io,
    metadata: Metadata,
    mappings: [2]objects.Mapping,
    stores: [2]objects.Store,
    parents: [2]Dir,
    dirs: [2]Dir,
    data: files.Store,
    name: [48]u8,
    name_len: usize,
    failed: bool = false,

    /// Existing bindings choose their recorded pair. Migration uses the supplied
    /// pair and leaves old immutable objects intact, even after uncertain RPCs.
    pub fn open(gpa: std.mem.Allocator, io: Io, metadata: Metadata, config: []const objects.Mapping, inode: u64, migration_pair: [2]u64) !Access {
        return openMode(gpa, io, metadata, config, inode, migration_pair, false);
    }

    pub fn openMode(gpa: std.mem.Allocator, io: Io, metadata: Metadata, config: []const objects.Mapping, inode: u64, migration_pair: [2]u64, repair: bool) !Access {
        const head = try metadata.get(metadata.context, inode);
        if (head.id != inode or head.kind != .file) return error.NotFile;
        if (head.replicas != .two) return error.InvalidReplicaPolicy;
        if (repair and head.mutable_file == null) return error.MissingSeal;
        const pair = if (head.mutable_file) |file| file.backends else migration_pair;
        if (pair[0] == 0 or pair[1] == 0 or pair[0] == pair[1]) return error.InvalidReplicaPolicy;
        const first = try metadata.backend(metadata.context, pair[0]);
        const second = try metadata.backend(metadata.context, pair[1]);
        if (first.id != pair[0] or second.id != pair[1] or first.failure_domain == 0 or second.failure_domain == 0 or first.failure_domain == second.failure_domain) return error.InvalidReplicaPolicy;
        const generation = if (head.mutable_file) |file| file.generation else randomId(io);
        var self: Access = undefined;
        self.io = io;
        self.metadata = metadata;
        self.failed = false;
        self.name_len = (try std.fmt.bufPrint(&self.name, "{d}-{d}", .{ inode, generation })).len;
        var count: usize = 0;
        errdefer for (0..count) |i| {
            self.dirs[i].close(io);
            self.parents[i].close(io);
            self.stores[i].close();
        };
        for (pair, 0..) |id, i| {
            self.mappings[i] = try objects.mappingFor(config, id);
            const store = try objects.Store.openMapping(io, self.mappings[i], false);
            errdefer store.close();
            if (head.mutable_file == null) {
                store.root.createDir(io, "mutable", .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                try objects.syncDir(io, store.root);
            }
            const parent = try store.root.openDir(io, "mutable", .{ .iterate = true, .follow_symlinks = false });
            errdefer parent.close(io);
            if (try mount.mountId(io, store.root) != try mount.mountId(io, parent)) return error.BackendMountMismatch;
            if (head.mutable_file == null) {
                try parent.createDir(io, self.name[0..self.name_len], .default_dir);
                try objects.syncDir(io, parent);
            }
            const dir = try parent.openDir(io, self.name[0..self.name_len], .{ .iterate = true, .follow_symlinks = false });
            errdefer dir.close(io);
            if (try mount.mountId(io, store.root) != try mount.mountId(io, dir)) return error.BackendMountMismatch;
            self.stores[i] = store;
            self.parents[i] = parent;
            self.dirs[i] = dir;
            count += 1;
        }
        // Different declarations must not alias the very same backend directory.
        const same_directory = same: {
            objects.validateDirectory(io, self.stores[0].root, self.stores[1].root) catch |err| switch (err) {
                error.BackendMountMismatch => break :same false,
                else => return err,
            };
            break :same true;
        };
        if (same_directory) return error.DuplicateBackendRoot;
        const a = try self.stores[0].root.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(a);
        const b = try self.stores[1].root.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(b);
        if (std.mem.eql(u8, a, b)) return error.DuplicateBackendRoot;
        const identity: @import("file_wal.zig").Identity = .{ .inode = inode, .generation = generation };
        self.data = if (head.mutable_file == null)
            try files.Store.create(gpa, io, identity, self.dirs)
        else
            try files.Store.openMode(gpa, io, identity, self.dirs, if (repair) head.mutable_file.?.next_sequence else null);
        errdefer self.data.close();
        if (head.mutable_file == null) {
            if (head.current_version != 0) try self.seed(head.current_version, config);
            try self.data.sync();
            try self.validate();
            try self.publish(.{ .attach = .{ .inode = inode, .expected_version = head.current_version, .file = .{
                .generation = generation,
                .next_sequence = self.data.checkpoint.next,
                .size = self.data.checkpoint.size,
                .backends = pair,
            } } });
        }
        try self.sync();
        return self;
    }

    pub fn close(self: *Access) void {
        self.data.close();
        for (0..2) |i| {
            self.dirs[i].close(self.io);
            self.parents[i].close(self.io);
            self.stores[i].close();
        }
        self.* = undefined;
    }

    fn seed(self: *Access, version_id: u64, config: []const objects.Mapping) !void {
        const version = try self.metadata.version(self.metadata.context, version_id);
        if (version.id != version_id or version.inode != self.data.session.identity.inode) return error.InvalidVersion;
        const source = source: {
            for (version.backends) |id| {
                if (id == 0) continue;
                const store = objects.openMapped(self.io, config, id, false) catch continue;
                defer store.close();
                break :source store.openVerified(version) catch continue;
            }
            return error.NoHealthyReplica;
        };
        defer source.close(self.io);
        var buffer: [256 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < version.size) {
            const count = try source.readPositional(self.io, &.{buffer[0..@min(buffer.len, version.size - offset)]}, offset);
            if (count == 0) return error.SourceChanged;
            try self.validate();
            try self.data.write(buffer[0..count], offset);
            offset += count;
        }
        // Migration alone needs a whole-file readback. Ordinary writes do not.
        for (self.data.session.replicas) |replica| if (!objects.matches(try objects.hash(self.io, replica.data), version)) return error.ChecksumMismatch;
    }

    fn validate(self: *Access) !void {
        if (self.failed or self.data.session.failed) return error.WalSessionFailed;
        for (0..2) |i| {
            try self.stores[i].validateMapping(self.mappings[i]);
            const parent = try self.stores[i].root.openDir(self.io, "mutable", .{ .follow_symlinks = false });
            defer parent.close(self.io);
            try objects.validateDirectory(self.io, self.parents[i], parent);
            const dir = try parent.openDir(self.io, self.name[0..self.name_len], .{ .follow_symlinks = false });
            defer dir.close(self.io);
            try objects.validateDirectory(self.io, self.dirs[i], dir);
            const file = try dir.openFile(self.io, "data", .{ .follow_symlinks = false, .allow_directory = false });
            defer file.close(self.io);
            if ((try file.stat(self.io)).inode != (try self.data.session.replicas[i].data.stat(self.io)).inode) return error.BackendMountMismatch;
        }
    }

    fn current(self: *Access) !m.MutableFile {
        const identity = self.data.session.identity;
        const head = try self.metadata.get(self.metadata.context, identity.inode);
        const file = head.mutable_file orelse return error.StorageConflict;
        if (head.id != identity.inode or head.kind != .file or head.replicas != .two or head.current_version != 0 or file.generation != identity.generation or !std.mem.eql(u64, &file.backends, &.{ self.mappings[0].id, self.mappings[1].id })) return error.StorageConflict;
        if (file.next_sequence > self.data.session.next) return error.StaleFileState;
        return file;
    }

    fn publish(self: *Access, update: m.MutableUpdate) !void {
        // The metadata transport must reuse this request across its own retries.
        const result = try self.metadata.apply(self.metadata.context, .{ .request_id = randomId(self.io), .command = .{ .mutable_file = update } });
        if (result.status != .ok) return error.MetadataConflict;
        if (result.inode != self.data.session.identity.inode) return error.InvalidResponse;
    }

    pub fn write(self: *Access, bytes: []const u8, offset: u64) !void {
        errdefer self.failed = true;
        try self.validate();
        _ = try self.current();
        try self.data.write(bytes, offset);
        try self.validate();
        if (bytes.len != 0) try self.touchModified();
    }

    pub fn truncate(self: *Access, length: u64) !void {
        errdefer self.failed = true;
        try self.validate();
        _ = try self.current();
        try self.data.truncate(length);
        try self.validate();
        try self.touchModified();
    }

    // Commit after the data operation, before acknowledging it. Recovery and
    // checkpoints must not retimestamp data or overwrite a later explicit time.
    // This is not atomic with the WAL: a failed call may still have changed data.
    fn touchModified(self: *Access) !void {
        const nanos = Io.Clock.real.now(self.io).toNanoseconds();
        const time: m.Timestamp = .{
            .seconds = @intCast(@divFloor(nanos, std.time.ns_per_s)),
            .nanoseconds = @intCast(@mod(nanos, std.time.ns_per_s)),
        };
        if (!m.validTimestamp(time)) return error.InvalidTimestamp;
        const inode = self.data.session.identity.inode;
        const result = try self.metadata.apply(self.metadata.context, .{
            .request_id = randomId(self.io),
            .command = .{ .set_times = .{ .inode = inode, .mtime = time, .ctime = time } },
        });
        if (result.status != .ok) return error.MetadataConflict;
        if (result.inode != inode) return error.InvalidResponse;
    }

    pub fn read(self: *Access, bytes: []u8, offset: u64) !usize {
        var timing = @import("latency_trace.zig").Timing(5).start();
        errdefer self.failed = true;
        try self.validate();
        timing.mark(0);
        _ = try self.current();
        timing.mark(1);
        _ = try self.replicaSize();
        const count = try self.readCompared(bytes, offset);
        timing.mark(2);
        try self.data.verifyRead(offset, bytes[0..count], bytes.len);
        timing.mark(3);
        try self.validate();
        timing.mark(4);
        timing.finish("read", self.data.session.identity.inode, bytes.len, self.data.session.end);
        return count;
    }

    // Bounded scratch space even when the caller supplies a large read buffer.
    // Agreement detects divergence, not identical corruption on both replicas.
    fn readCompared(self: *Access, bytes: []u8, offset: u64) !usize {
        var other: [64 * 1024]u8 = undefined;
        var used: usize = 0;
        while (used < bytes.len) {
            const chunk = bytes[used..][0..@min(other.len, bytes.len - used)];
            const position = std.math.add(u64, offset, used) catch return error.InvalidRange;
            const a = try self.data.session.replicas[0].data.readPositionalAll(self.io, chunk, position);
            const b = try self.data.session.replicas[1].data.readPositionalAll(self.io, other[0..chunk.len], position);
            if (a != b or !std.mem.eql(u8, chunk[0..a], other[0..b])) return error.ReplicaContentMismatch;
            used += a;
            if (a != chunk.len) break;
        }
        return used;
    }

    fn replicaSize(self: *Access) !u64 {
        const a = (try self.data.session.replicas[0].data.stat(self.io)).size;
        const b = (try self.data.session.replicas[1].data.stat(self.io)).size;
        if (a != b) return error.ReplicaSizeMismatch;
        return a;
    }

    pub const Scrub = struct {
        size: u64,
        next_sequence: u64,
        sha256: [32]u8,
    };

    /// Serialized with other access operations, under both exclusive data locks.
    /// Does not checkpoint, collect logs, or choose a repair source on divergence.
    pub fn scrub(self: *Access) !Scrub {
        errdefer self.failed = true;
        try self.validate();
        _ = try self.current();
        try self.data.session.verifyPending(self.data.checkpoint.next, self.data.checkpoint.size);
        const length = try self.replicaSize();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < length) {
            try self.validate();
            const bytes = buffer[0..@min(buffer.len, length - offset)];
            if (try self.readCompared(bytes, offset) != bytes.len) return error.SourceChanged;
            hasher.update(bytes);
            offset += bytes.len;
        }
        if (try self.replicaSize() != length) return error.SourceChanged;
        try self.validate();
        _ = try self.current();
        var result: Scrub = .{ .size = length, .next_sequence = self.data.session.next, .sha256 = undefined };
        hasher.final(&result.sha256);
        if (self.data.seal) |baseline| {
            if (result.size != baseline.size or !std.mem.eql(u8, &result.sha256, &baseline.sha256)) return error.SealedContentMismatch;
        }
        return result;
    }

    pub fn seal(self: *Access) !void {
        errdefer self.failed = true;
        try self.validate();
        _ = try self.current();
        try self.data.establishSeal();
        try self.validate();
        try self.sync();
    }

    pub fn size(self: *Access) !u64 {
        var timing = @import("latency_trace.zig").Timing(4).start();
        errdefer self.failed = true;
        try self.validate();
        timing.mark(0);
        _ = try self.current();
        timing.mark(1);
        try self.data.verifyRead(0, "", 0);
        timing.mark(2);
        const size_value = try self.replicaSize();
        timing.mark(3);
        timing.finish("size", self.data.session.identity.inode, size_value, self.data.session.end);
        return size_value;
    }

    pub fn sync(self: *Access) !void {
        errdefer self.failed = true;
        try self.validate();
        const head = try self.current();
        try self.data.sync();
        try self.validate();
        if (head.next_sequence == self.data.checkpoint.next) {
            if (head.size != self.data.checkpoint.size) return error.StaleFileState;
            return;
        }
        try self.publish(.{ .checkpoint = .{
            .inode = self.data.session.identity.inode,
            .generation = head.generation,
            .expected_sequence = head.next_sequence,
            .next_sequence = self.data.checkpoint.next,
            .size = self.data.checkpoint.size,
        } });
    }

    pub fn collect(self: *Access) !void {
        try self.sync();
        errdefer self.failed = true;
        try self.validate();
        try self.data.collect();
    }
};

fn randomId(io: Io) u64 {
    var id: u64 = 0;
    while (id == 0) io.random(std.mem.asBytes(&id));
    return id;
}
