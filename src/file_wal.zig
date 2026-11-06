//! Redo engine for one exclusively owned mutable file and its two backend WALs.
//! The caller owns descriptors, persists their directory entries before use, and
//! excludes all readers/writers until recovery completes. No automatic WAL GC.
//! Both data files must retain their established baseline and identity; a missing
//! data file or WAL must not be silently recreated and passed to recovery.
const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;
const evidence_module = @import("wal_evidence.zig");
const header_size = 112;
pub const max_write = 1024 * 1024;
pub const max_log = 64 * 1024 * 1024;
const magic = "NASWAL01";

pub const Identity = struct { inode: u64, generation: u64 };
pub const Replica = struct { log: File, data: File };
const Operation = enum(u32) { write = 1, truncate = 2 };
const Record = struct { operation: Operation, offset: u64, payload: []const u8, end: usize };

fn checksum(header: []const u8, payload: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(header);
    hash.update(payload);
    return hash.finalResult();
}

fn encode(gpa: Allocator, identity: Identity, sequence: u64, operation: Operation, offset: u64, payload: []const u8) ![]u8 {
    if (identity.inode == 0 or identity.generation == 0 or sequence == 0) return error.InvalidIdentity;
    if (payload.len > max_write or offset > std.math.maxInt(i64) - payload.len) return error.InvalidRange;
    const bytes = try gpa.alloc(u8, header_size + payload.len);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u64, bytes[8..16], sequence, .little);
    std.mem.writeInt(u64, bytes[16..24], identity.inode, .little);
    std.mem.writeInt(u64, bytes[24..32], identity.generation, .little);
    std.mem.writeInt(u64, bytes[32..40], offset, .little);
    std.mem.writeInt(u32, bytes[40..44], @intCast(payload.len), .little);
    std.mem.writeInt(u32, bytes[44..48], @backingInt(operation), .little);
    @memcpy(bytes[header_size..], payload);
    @memcpy(bytes[48..80], &checksum(bytes[0..48], payload));
    @memcpy(bytes[80..112], &checksum(bytes[0..80], ""));
    return bytes;
}

// Only an incomplete final frame may be discarded. Complete corrupt frames fail closed.
fn decode(bytes: []const u8, start: usize, identity: Identity, sequence: u64) !?Record {
    const rest = bytes[start..];
    if (rest.len < header_size) return null;
    if (!std.mem.eql(u8, rest[0..8], magic)) return error.CorruptWal;
    // Authenticate the length before treating a short payload as a torn tail.
    if (!std.mem.eql(u8, rest[80..112], &checksum(rest[0..80], ""))) return error.CorruptWal;
    if (std.mem.readInt(u64, rest[8..16], .little) != sequence) return error.WalSequenceMismatch;
    if (std.mem.readInt(u64, rest[16..24], .little) != identity.inode or
        std.mem.readInt(u64, rest[24..32], .little) != identity.generation) return error.WalIdentityMismatch;
    const size = std.mem.readInt(u32, rest[40..44], .little);
    const operation = std.enums.fromInt(Operation, std.mem.readInt(u32, rest[44..48], .little)) orelse return error.CorruptWal;
    const offset = std.mem.readInt(u64, rest[32..40], .little);
    if (size > max_write or offset > @as(u64, std.math.maxInt(i64)) - size or (operation == .truncate and size != 0)) return error.CorruptWal;
    if (rest.len < header_size + size) return null;
    const payload = rest[header_size..][0..size];
    if (!std.mem.eql(u8, rest[48..80], &checksum(rest[0..48], payload))) return error.CorruptWal;
    return .{ .operation = operation, .offset = offset, .payload = payload, .end = start + header_size + size };
}

fn scan(bytes: []const u8, identity: Identity, first: u64) !struct { end: usize, next: u64 } {
    var end: usize = 0;
    var next: u64 = first;
    while (try decode(bytes, end, identity, next)) |record| {
        if (next == std.math.maxInt(u64)) return error.WalSequenceExhausted;
        end = record.end;
        next += 1;
    }
    return .{ .end = end, .next = next };
}

fn readLog(gpa: Allocator, io: Io, file: File) ![]u8 {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > max_log) return error.WalCapacityExceeded;
    return readLogBytes(gpa, io, file, stat.size);
}

fn readLogBytes(gpa: Allocator, io: Io, file: File, reported_size: u64) ![]u8 {
    var bytes = try std.ArrayList(u8).initCapacity(gpa, @intCast(reported_size));
    errdefer bytes.deinit(gpa);
    try bytes.resize(gpa, @intCast(reported_size));
    if (try file.readPositionalAll(io, bytes.items, 0) != bytes.items.len) return error.WalChanged;
    // Reopened CIFS handles can under-report length after server-side changes.
    // Treat stat as an allocation hint; recovery must inspect the actual tail.
    var buffer: [64 * 1024]u8 = undefined;
    while (bytes.items.len < max_log) {
        const window = buffer[0..@min(buffer.len, max_log - bytes.items.len)];
        const count = try file.readPositionalAll(io, window, bytes.items.len);
        try bytes.appendSlice(gpa, window[0..count]);
        if (count != window.len) break;
    }
    var extra: [1]u8 = undefined;
    if (try file.readPositionalAll(io, &extra, bytes.items.len) != 0)
        return if (bytes.items.len == max_log) error.WalCapacityExceeded else error.WalChanged;
    return bytes.toOwnedSlice(gpa);
}

test "WAL stale size cannot hide later valid records or complete corruption" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(t.io, "wal", .{ .read = true });
    defer file.close(t.io);
    const identity: Identity = .{ .inode = 2, .generation = 7 };
    const first = try encode(t.allocator, identity, 1, .write, 0, "first");
    defer t.allocator.free(first);
    const payload = try t.allocator.alloc(u8, 128 * 1024);
    defer t.allocator.free(payload);
    @memset(payload, 'X');
    const second = try encode(t.allocator, identity, 2, .write, 0, payload);
    defer t.allocator.free(second);
    try file.writePositionalAll(t.io, first, 0);
    try file.writePositionalAll(t.io, second, first.len);
    const end = first.len + second.len;
    try file.writePositionalAll(t.io, "torn", end);
    for ([_]u64{ 0, first.len, end + 4 }) |reported_size| {
        const bytes = try readLogBytes(t.allocator, t.io, file, reported_size);
        defer t.allocator.free(bytes);
        try t.expectEqual(end + 4, bytes.len);
        const scanned = try scan(bytes, identity, 1);
        try t.expectEqual(end, scanned.end);
        try t.expectEqual(@as(u64, 3), scanned.next);
    }
    try file.writePositionalAll(t.io, "Q", first.len + header_size);
    const corrupt = try readLogBytes(t.allocator, t.io, file, first.len);
    defer t.allocator.free(corrupt);
    try t.expectError(error.CorruptWal, scan(corrupt, identity, 1));
    try t.expectError(error.WalChanged, readLogBytes(t.allocator, t.io, file, end + 5));
}

fn append(io: Io, replica: Replica, bytes: []const u8, offset: u64) !void {
    try replica.log.writePositionalAll(io, bytes, offset);
    try replica.log.sync(io);
}

fn restoreLog(io: Io, replica: Replica, bytes: []const u8) !void {
    // Shared bytes were checked before recovery. Never rewrite a durable prefix:
    // interruption during repair must leave its existing records intact.
    const length = (try replica.log.stat(io)).size;
    if (length < bytes.len) try replica.log.writePositionalAll(io, bytes[@intCast(length)..], length);
    try replica.log.setLength(io, bytes.len);
    try replica.log.sync(io);
}

fn apply(io: Io, replica: Replica, record: Record) !void {
    switch (record.operation) {
        .write => try replica.data.writePositionalAll(io, record.payload, record.offset),
        .truncate => try replica.data.setLength(io, record.offset),
    }
}

fn syncData(io: Io, replica: Replica) !void {
    try replica.data.sync(io);
}

/// Fixed read-ahead avoids an SMB request per tiny record. The limit is the
/// acknowledged in-session end, and the physical EOF is checked separately.
const LogReader = struct {
    io: Io,
    file: File,
    limit: u64,
    position: u64 = 0,
    used: usize = 0,
    available: usize = 0,
    buffer: [64 * 1024]u8 = undefined,

    fn readExact(self: *LogReader, destination: []u8) !void {
        var copied: usize = 0;
        while (copied < destination.len) {
            if (self.used == self.available) {
                if (self.position >= self.limit) return error.WalChanged;
                const bytes = self.buffer[0..@min(self.buffer.len, self.limit - self.position)];
                if (try self.file.readPositionalAll(self.io, bytes, self.position) != bytes.len) return error.WalChanged;
                self.position += bytes.len;
                self.used = 0;
                self.available = bytes.len;
            }
            const count = @min(destination.len - copied, self.available - self.used);
            @memcpy(destination[copied..][0..count], self.buffer[self.used..][0..count]);
            self.used += count;
            copied += count;
        }
    }

    fn checkEnd(self: *LogReader) !void {
        var extra: [1]u8 = undefined;
        if (try self.file.readPositionalAll(self.io, &extra, self.limit) != 0) return error.WalChanged;
    }
};

/// Both operations are joined even if either fails. No sequential fallback.
fn pair(io: Io, replicas: [2]Replica, comptime function: anytype, args: anytype) !void {
    var first = try io.concurrent(function, .{ io, replicas[0] } ++ args);
    const second = @call(.auto, function, .{ io, replicas[1] } ++ args);
    const first_result = first.await(io);
    try first_result;
    try second;
}

pub const Session = struct {
    io: Io,
    allocator: Allocator,
    identity: Identity,
    replicas: [2]Replica,
    end: u64,
    next: u64,
    failed: bool = false,

    /// Accepts a longer valid prefix from either backend, including an unacknowledged
    /// operation. Conflicting records or complete corruption require intervention.
    /// All validation precedes mutation; both WALs become durable before any replay.
    pub fn recover(gpa: Allocator, io: Io, identity: Identity, replicas: [2]Replica) !Session {
        return recoverFrom(gpa, io, identity, replicas, 1);
    }

    /// The enclosing durable checkpoint establishes this WAL's first sequence.
    pub fn recoverFrom(gpa: Allocator, io: Io, identity: Identity, replicas: [2]Replica, first: u64) !Session {
        if (identity.inode == 0 or identity.generation == 0 or first == 0 or first == std.math.maxInt(u64)) return error.InvalidIdentity;
        const a = try readLog(gpa, io, replicas[0].log);
        defer gpa.free(a);
        const b = try readLog(gpa, io, replicas[1].log);
        defer gpa.free(b);
        const sa = try scan(a, identity, first);
        const sb = try scan(b, identity, first);
        const common = @min(a.len, b.len);
        if (!std.mem.eql(u8, a[0..common], b[0..common])) return error.WalDiverged;
        const selected = if (sa.end >= sb.end) sa else sb;
        const bytes = if (sa.end >= sb.end) a[0..sa.end] else b[0..sb.end];
        try pair(io, replicas, restoreLog, .{bytes});
        var offset: usize = 0;
        var sequence: u64 = first;
        while (try decode(bytes, offset, identity, sequence)) |record| {
            try pair(io, replicas, apply, .{record});
            offset = record.end;
            sequence += 1;
        }
        try pair(io, replicas, syncData, .{});
        return .{ .io = io, .allocator = gpa, .identity = identity, .replicas = replicas, .end = selected.end, .next = selected.next };
    }

    pub fn write(self: *Session, bytes: []const u8, offset: u64) !void {
        if (self.failed) return error.WalSessionFailed;
        if (bytes.len == 0) return;
        try self.mutate(.write, offset, bytes);
    }

    pub fn truncate(self: *Session, size: u64) !void {
        try self.mutate(.truncate, size, "");
    }

    /// Validate acknowledged in-session logs exactly (no torn-tail recovery),
    /// then compare their final effects before the enclosing store retires them.
    pub fn verifyPending(self: *Session, first: u64, baseline_size: u64) !void {
        if (self.failed) return error.WalSessionFailed;
        errdefer self.failed = true;
        const a = try readLog(self.allocator, self.io, self.replicas[0].log);
        defer self.allocator.free(a);
        {
            const b = try readLog(self.allocator, self.io, self.replicas[1].log);
            defer self.allocator.free(b);
            if (!std.mem.eql(u8, a, b)) return error.WalDiverged;
        }
        const scanned = try scan(a, self.identity, first);
        if (a.len != self.end or scanned.end != a.len or scanned.next != self.next) return error.WalChanged;
        var evidence: evidence_module.Evidence = .{ .allocator = self.allocator, .size = baseline_size };
        defer evidence.deinit();
        var offset: usize = 0;
        var sequence = first;
        while (try decode(a, offset, self.identity, sequence)) |record| {
            switch (record.operation) {
                .write => try evidence.write(record.offset, record.payload),
                .truncate => try evidence.truncate(record.offset),
            }
            offset = record.end;
            sequence += 1;
        }
        const files = [2]File{ self.replicas[0].data, self.replicas[1].data };
        try evidence.verify(self.io, files);
    }

    /// Stream both complete WALs, retaining only one frame per replica and the
    /// caller's requested window. No persistent-log integrity cache is trusted.
    pub fn verifyRead(self: *Session, first: u64, baseline_size: u64, read: evidence_module.Read) !void {
        if (self.failed) return error.WalSessionFailed;
        errdefer self.failed = true;
        if (first == 0 or first > self.next) return error.WalChanged;
        for (self.replicas) |replica| {
            const stat = try replica.log.stat(self.io);
            if (stat.kind != .file or stat.size > max_log) return error.WalCapacityExceeded;
            if (stat.size != self.end) return error.WalChanged;
        }
        const observed_size = (try self.replicas[0].data.stat(self.io)).size;
        var evidence = try evidence_module.ReadEvidence.init(self.allocator, baseline_size, observed_size, read);
        defer evidence.deinit();
        const capacity: usize = @intCast(@min(self.end, max_write + header_size));
        const a = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(a);
        const b = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(b);
        var left: LogReader = .{ .io = self.io, .file = self.replicas[0].log, .limit = self.end };
        var right: LogReader = .{ .io = self.io, .file = self.replicas[1].log, .limit = self.end };
        var offset: u64 = 0;
        var sequence = first;
        while (offset < self.end) {
            if (self.end - offset < header_size) return error.WalChanged;
            try left.readExact(a[0..header_size]);
            try right.readExact(b[0..header_size]);
            if (!std.mem.eql(u8, a[0..header_size], b[0..header_size])) return error.WalDiverged;
            // Authenticate the header, identity and length before using its size.
            _ = try decode(a[0..header_size], 0, self.identity, sequence);
            const length = header_size + std.mem.readInt(u32, a[40..44], .little);
            if (length > self.end - offset) return error.WalChanged;
            try left.readExact(a[header_size..length]);
            try right.readExact(b[header_size..length]);
            if (!std.mem.eql(u8, a[header_size..length], b[header_size..length])) return error.WalDiverged;
            const record = (try decode(a[0..length], 0, self.identity, sequence)) orelse return error.WalChanged;
            switch (record.operation) {
                .write => try evidence.write(record.offset, record.payload),
                .truncate => evidence.truncate(record.offset),
            }
            offset += length;
            sequence = std.math.add(u64, sequence, 1) catch return error.WalSequenceExhausted;
        }
        if (sequence != self.next) return error.WalChanged;
        try left.checkEnd();
        try right.checkEnd();
        try evidence.verify(self.io, .{ self.replicas[0].data, self.replicas[1].data });
    }

    fn mutate(self: *Session, operation: Operation, offset: u64, payload: []const u8) !void {
        if (self.failed) return error.WalSessionFailed;
        // Reserve a representable, reopenable first sequence for the next epoch.
        if (self.next >= std.math.maxInt(u64) - 1) return error.WalSequenceExhausted;
        const bytes = try encode(self.allocator, self.identity, self.next, operation, offset, payload);
        defer self.allocator.free(bytes);
        if (self.end + bytes.len > max_log) return error.WalCapacityExceeded;
        errdefer self.failed = true;
        try pair(self.io, self.replicas, append, .{ bytes, self.end });
        const record = (try decode(bytes, 0, self.identity, self.next)).?;
        try pair(self.io, self.replicas, apply, .{record});
        self.end += bytes.len;
        self.next += 1;
    }

    /// WAL is retained: checkpoint publication and safe reclamation belong to the
    /// enclosing file/metadata protocol and are deliberately not inferred here.
    pub fn sync(self: *Session) !void {
        if (self.failed) return error.WalSessionFailed;
        errdefer self.failed = true;
        try pair(self.io, self.replicas, syncData, .{});
    }
};
