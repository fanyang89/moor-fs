//! Checkpointed mutable files. Directories are dedicated to one logical file;
//! the caller validates their NAS mappings and persists their parent entries.
//! Owns data/WAL descriptors and exclusive data locks, but borrows directories.
const std = @import("std");
const wal = @import("file_wal.zig");
const objects = @import("objects.zig");
const Seal = @import("file_seal.zig").Seal;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const checkpoint_size = 72;

const Checkpoint = struct {
    next: u64,
    size: u64,

    fn encode(self: Checkpoint, identity: wal.Identity) [checkpoint_size]u8 {
        var bytes: [checkpoint_size]u8 = undefined;
        @memcpy(bytes[0..8], "NASCP001");
        std.mem.writeInt(u64, bytes[8..16], identity.inode, .little);
        std.mem.writeInt(u64, bytes[16..24], identity.generation, .little);
        std.mem.writeInt(u64, bytes[24..32], self.next, .little);
        std.mem.writeInt(u64, bytes[32..40], self.size, .little);
        std.crypto.hash.sha2.Sha256.hash(bytes[0..40], bytes[40..72], .{});
        return bytes;
    }

    fn read(io: Io, dir: Dir, identity: wal.Identity) !?Checkpoint {
        const file = dir.openFile(io, "checkpoint", .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        var bytes: [checkpoint_size]u8 = undefined;
        if ((try file.stat(io)).size != bytes.len or try file.readPositionalAll(io, &bytes, 0) != bytes.len) return error.CorruptCheckpoint;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..40], &hash, .{});
        if (!std.mem.eql(u8, bytes[0..8], "NASCP001") or !std.mem.eql(u8, bytes[40..72], &hash)) return error.CorruptCheckpoint;
        if (std.mem.readInt(u64, bytes[8..16], .little) != identity.inode or std.mem.readInt(u64, bytes[16..24], .little) != identity.generation) return error.WalIdentityMismatch;
        const next = std.mem.readInt(u64, bytes[24..32], .little);
        const size = std.mem.readInt(u64, bytes[32..40], .little);
        if (next == 0 or next == std.math.maxInt(u64) or size > std.math.maxInt(i64)) return error.CorruptCheckpoint;
        return .{ .next = next, .size = size };
    }
};

fn logName(buffer: *[32]u8, next: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "wal-{d}", .{next});
}

fn publish(io: Io, dir: Dir, bytes: *const [checkpoint_size]u8) !void {
    var random: [16]u8 = undefined;
    io.random(&random);
    const name = "checkpoint-" ++ std.fmt.bytesToHex(random, .lower);
    const temporary = try dir.createFile(io, name, .{ .exclusive = true });
    defer temporary.close(io);
    defer dir.deleteFile(io, name) catch {};
    try temporary.writePositionalAll(io, bytes, 0);
    try temporary.sync(io);
    try dir.rename(name, dir, "checkpoint", io);
    try objects.syncDir(io, dir);
}

fn publishBoth(io: Io, dirs: [2]Dir, checkpoint: Checkpoint, identity: wal.Identity) !void {
    const bytes = checkpoint.encode(identity);
    var first = try io.concurrent(publish, .{ io, dirs[0], &bytes });
    const second = publish(io, dirs[1], &bytes);
    const result = first.await(io);
    try result;
    try second;
}

fn openData(io: Io, dir: Dir, create: bool) !File {
    const file = if (create)
        try dir.createFile(io, "data", .{ .read = true, .exclusive = true })
    else
        try dir.openFile(io, "data", .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false });
    errdefer file.close(io);
    try lockData(io, file);
    return file;
}

fn lockData(io: Io, file: File) !void {
    if (@import("builtin").os.tag != .linux) {
        if (!try file.tryLock(io, .exclusive)) return error.FileBusy;
        return;
    }
    // CIFS can report EACCES for a conflicting SMB lock, while Zig's current
    // tryLock only recognizes EAGAIN. Neither result grants ownership.
    const posix = std.posix;
    while (true) switch (posix.errno(posix.system.flock(file.handle, posix.LOCK.EX | posix.LOCK.NB))) {
        .SUCCESS => return,
        .INTR => continue,
        .AGAIN, .ACCES => return error.FileBusy,
        .NOLCK => return error.SystemResources,
        .OPNOTSUPP => return error.FileLocksUnsupported,
        else => |err| return posix.unexpectedErrno(err),
    };
}

fn newLog(io: Io, dir: Dir, next: u64) !File {
    var buffer: [32]u8 = undefined;
    const name = try logName(&buffer, next);
    const file = dir.createFile(io, name, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
        // A crash before checkpoint publication may leave an unused empty log.
        error.PathAlreadyExists => try dir.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }),
        else => return err,
    };
    errdefer file.close(io);
    if ((try file.stat(io)).size != 0) return error.UnexpectedWal;
    try file.sync(io);
    try objects.syncDir(io, dir);
    return file;
}

pub const Store = struct {
    session: wal.Session,
    dirs: [2]Dir,
    checkpoint: Checkpoint,
    seal: ?Seal = null,

    /// Fresh files only; interrupted initialization is not silently retried.
    pub fn create(gpa: Allocator, io: Io, identity: wal.Identity, dirs: [2]Dir) !Store {
        if (identity.inode == 0 or identity.generation == 0) return error.InvalidIdentity;
        for (dirs) |dir| if (try Checkpoint.read(io, dir, identity) != null) return error.PathAlreadyExists;
        var replicas: [2]wal.Replica = undefined;
        var count: usize = 0;
        errdefer closeReplicas(io, replicas[0..count]);
        for (dirs, 0..) |dir, i| {
            const data = try openData(io, dir, true);
            errdefer data.close(io);
            try data.sync(io);
            const log = try newLog(io, dir, 1);
            replicas[i] = .{ .data = data, .log = log };
            count += 1;
        }
        const checkpoint: Checkpoint = .{ .next = 1, .size = 0 };
        try publishBoth(io, dirs, checkpoint, identity);
        return .{ .session = try wal.Session.recover(gpa, io, identity, replicas), .dirs = dirs, .checkpoint = checkpoint };
    }

    pub fn open(gpa: Allocator, io: Io, identity: wal.Identity, dirs: [2]Dir) !Store {
        return openMode(gpa, io, identity, dirs, null);
    }

    pub fn openMode(gpa: Allocator, io: Io, identity: wal.Identity, dirs: [2]Dir, repair_sequence: ?u64) !Store {
        // Lock every existing data inode first. A missing target may only be
        // created by explicit repair after authenticating the surviving source.
        var data: [2]?File = .{ null, null };
        errdefer for (data) |file| if (file) |opened| opened.close(io);
        for (dirs, 0..) |dir, i| {
            data[i] = openData(io, dir, false) catch |err| switch (err) {
                error.FileNotFound => if (repair_sequence != null) null else return err,
                else => return err,
            };
        }
        if (data[0] == null and data[1] == null) return error.NoVerifiedReplica;
        const ca = try Checkpoint.read(io, dirs[0], identity);
        const cb = try Checkpoint.read(io, dirs[1], identity);
        if (ca == null and cb == null) return error.MissingCheckpoint;
        const checkpoint = if (ca == null) cb.? else if (cb == null or ca.?.next >= cb.?.next) ca.? else cb.?;
        if (repair_sequence) |minimum| if (checkpoint.next < minimum) return error.StaleFileState;
        if (ca != null and cb != null and ca.?.next == cb.?.next and ca.?.size != cb.?.size) return error.CheckpointDiverged;
        // Normal recovery never recreates logs. Explicit repair may reconstruct
        // one absent empty log only after verifying both complete sealed files.
        var buffer: [32]u8 = undefined;
        const name = try logName(&buffer, checkpoint.next);
        var logs: [2]?File = .{ null, null };
        errdefer for (logs) |file| if (file) |opened| opened.close(io);
        for (dirs, 0..) |dir, i| {
            logs[i] = dir.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => if (repair_sequence != null) null else return err,
                else => return err,
            };
        }
        const missing_log = logs[0] == null or logs[1] == null;
        if (missing_log and (logs[0] == null and logs[1] == null or data[0] == null or data[1] == null)) return error.FileNotFound;
        const seal = try Seal.load(io, dirs, identity, checkpoint.next, checkpoint.size);
        if (repair_sequence != null and seal == null) return error.MissingSeal;
        if (seal) |baseline| {
            // A valid baseline is published only after rotation; writes must
            // durably invalidate both copies before appending any redo record.
            for (logs) |file| if (file) |opened| {
                if ((try opened.stat(io)).size != 0) return error.SealWithPendingWal;
            };
            if (missing_log or data[0] == null or data[1] == null) {
                if (ca == null or cb == null or !std.meta.eql(ca.?, cb.?)) return error.CheckpointDiverged;
                for (dirs) |dir| if (try Seal.read(io, dir, identity) == null) return error.MissingSeal;
            }
            if (data[0] == null or data[1] == null) {
                // Rebuild only one absent data file, not missing control files
                // or an offline backend. Both persisted baselines must agree.
                const missing: usize = if (data[0] == null) 0 else 1;
                if (!try baseline.matches(io, data[1 - missing].?)) return error.NoVerifiedReplica;
                data[missing] = try openData(io, dirs[missing], true);
                try data[missing].?.sync(io);
                try objects.syncDir(io, dirs[missing]);
                @import("repair_fault.zig").checkpoint(.mutable_created);
            }
            if (missing_log) {
                // Both files must already match. Never discard potential redo
                // evidence by combining log reconstruction with data repair.
                try baseline.verify(io, .{ data[0].?, data[1].? }, false);
                const missing: usize = if (logs[0] == null) 0 else 1;
                logs[missing] = try dirs[missing].createFile(io, name, .{ .read = true, .exclusive = true });
                try logs[missing].?.sync(io);
                try objects.syncDir(io, dirs[missing]);
                @import("repair_fault.zig").checkpoint(.mutable_wal_created);
            } else {
                try baseline.verify(io, .{ data[0].?, data[1].? }, repair_sequence != null);
            }
        }
        const replicas: [2]wal.Replica = .{ .{ .data = data[0].?, .log = logs[0].? }, .{ .data = data[1].?, .log = logs[1].? } };
        const session = try wal.Session.recoverFrom(gpa, io, identity, replicas, checkpoint.next);
        if (session.end == 0) {
            for (replicas) |replica| if ((try replica.data.stat(io)).size != checkpoint.size) return error.ReplicaSizeMismatch;
        }
        try publishBoth(io, dirs, checkpoint, identity);
        return .{ .session = session, .dirs = dirs, .checkpoint = checkpoint, .seal = seal };
    }

    pub fn close(self: *Store) void {
        closeReplicas(self.session.io, &self.session.replicas);
        self.* = undefined;
    }

    pub fn verifyRead(self: *Store, offset: u64, bytes: []const u8, requested: usize) !void {
        if (self.session.failed) return error.WalSessionFailed;
        if (self.session.end == 0) return;
        try self.session.verifyRead(self.checkpoint.next, self.checkpoint.size, .{ .offset = offset, .bytes = bytes, .requested = requested });
    }

    pub fn write(self: *Store, bytes: []const u8, offset: u64) !void {
        if (self.session.failed) return error.WalSessionFailed;
        if (bytes.len > wal.max_write or offset > std.math.maxInt(i64) - bytes.len) return error.InvalidRange;
        if (bytes.len == 0) return;
        try self.invalidateSeal();
        if (self.session.end + bytes.len + 112 > wal.max_log) try self.sync();
        try self.session.write(bytes, offset);
    }

    pub fn truncate(self: *Store, size: u64) !void {
        if (self.session.failed) return error.WalSessionFailed;
        if (size > std.math.maxInt(i64)) return error.InvalidRange;
        try self.invalidateSeal();
        if (self.session.end + 112 > wal.max_log) try self.sync();
        try self.session.truncate(size);
    }

    fn invalidateSeal(self: *Store) !void {
        if (self.seal == null) return;
        errdefer self.session.failed = true;
        for (self.dirs, 0..) |dir, index| {
            dir.deleteFile(self.session.io, "seal") catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try objects.syncDir(self.session.io, dir);
            if (index == 0) @import("repair_fault.zig").checkpoint(.seal_first_invalidated);
        }
        @import("repair_fault.zig").checkpoint(.seal_invalidated);
        self.seal = null;
    }

    /// Explicit full-file baseline: no whole-file hashing on ordinary fsync.
    pub fn establishSeal(self: *Store) !void {
        if (self.session.failed) return error.WalSessionFailed;
        errdefer self.session.failed = true;
        if (self.seal) |baseline| try baseline.verify(self.session.io, .{ self.session.replicas[0].data, self.session.replicas[1].data }, false);
        try self.sync();
        const a = try objects.hash(self.session.io, self.session.replicas[0].data);
        const b = try objects.hash(self.session.io, self.session.replicas[1].data);
        if (a.size != self.checkpoint.size or !std.meta.eql(a, b)) return error.ReplicaContentMismatch;
        const baseline: Seal = .{ .next = self.checkpoint.next, .size = a.size, .sha256 = a.sha256 };
        for (self.dirs, 0..) |dir, index| {
            try baseline.publish(self.session.io, dir, self.session.identity);
            if (index == 0) @import("repair_fault.zig").checkpoint(.seal_first_published);
        }
        @import("repair_fault.zig").checkpoint(.seal_published);
        self.seal = baseline;
    }

    /// A successful sync establishes a new data baseline and switches WALs.
    /// Publication errors freeze the session; recovery decides which epoch won.
    pub fn sync(self: *Store) !void {
        try self.session.sync();
        try self.session.verifyPending(self.checkpoint.next, self.checkpoint.size);
        if (self.session.next == self.checkpoint.next) return;
        errdefer self.session.failed = true;
        const io = self.session.io;
        const size = (try self.session.replicas[0].data.stat(io)).size;
        if ((try self.session.replicas[1].data.stat(io)).size != size) return error.ReplicaSizeMismatch;
        const checkpoint: Checkpoint = .{ .next = self.session.next, .size = size };
        const a = try newLog(io, self.dirs[0], checkpoint.next);
        errdefer a.close(io);
        const b = try newLog(io, self.dirs[1], checkpoint.next);
        errdefer b.close(io);
        try publishBoth(io, self.dirs, checkpoint, self.session.identity);
        for (&self.session.replicas, [_]File{ a, b }) |*replica, log| {
            replica.log.close(io);
            replica.log = log;
        }
        self.session.end = 0;
        self.checkpoint = checkpoint;
    }

    /// Explicit, repeatable reclamation after both checkpoint files are durable.
    /// Failure leaves harmless older logs, and never removes the active/future log.
    pub fn collect(self: *Store) !void {
        if (self.session.failed) return error.WalSessionFailed;
        errdefer self.session.failed = true;
        for (self.dirs) |dir| {
            const checkpoint = (try Checkpoint.read(self.session.io, dir, self.session.identity)) orelse return error.MissingCheckpoint;
            if (!std.meta.eql(checkpoint, self.checkpoint)) return error.CheckpointDiverged;
        }
        for (self.dirs) |dir| {
            var iterator = dir.iterate();
            while (try iterator.next(self.session.io)) |entry| {
                if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "wal-")) continue;
                const sequence = std.fmt.parseInt(u64, entry.name[4..], 10) catch continue;
                var buffer: [32]u8 = undefined;
                if (sequence >= self.checkpoint.next or !std.mem.eql(u8, entry.name, try logName(&buffer, sequence))) continue;
                // CIFS may return a recently deleted entry from its directory
                // cache when collection is repeated on the same open directory.
                dir.deleteFile(self.session.io, entry.name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
            try objects.syncDir(self.session.io, dir);
        }
    }
};

fn closeReplicas(io: Io, replicas: []const wal.Replica) void {
    for (replicas) |replica| {
        replica.log.close(io);
        replica.data.close(io);
    }
}
