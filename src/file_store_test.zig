const std = @import("std");
const t = std.testing;
const files = @import("file_store.zig");
const wal = @import("file_wal.zig");
const identity: wal.Identity = .{ .inode = 42, .generation = 9 };
const Seal = @import("file_seal.zig").Seal;

const Fixture = struct {
    tmp: t.TmpDir,
    dirs: [2]std.Io.Dir,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(t.io, "a", .default_dir);
        try tmp.dir.createDir(t.io, "b", .default_dir);
        const a = try tmp.dir.openDir(t.io, "a", .{ .iterate = true });
        errdefer a.close(t.io);
        const b = try tmp.dir.openDir(t.io, "b", .{ .iterate = true });
        return .{ .tmp = tmp, .dirs = .{ a, b } };
    }

    fn deinit(self: *Fixture) void {
        for (self.dirs) |dir| dir.close(t.io);
        self.tmp.cleanup();
    }

    fn create(self: *Fixture) !files.Store {
        return files.Store.create(t.allocator, t.io, identity, self.dirs);
    }

    fn open(self: *Fixture) !files.Store {
        return files.Store.open(t.allocator, t.io, identity, self.dirs);
    }

    fn expect(self: *Fixture, expected: []const u8) !void {
        for (self.dirs) |dir| {
            const bytes = try dir.readFileAlloc(t.io, "data", t.allocator, .limited(1024));
            defer t.allocator.free(bytes);
            try t.expectEqualSlices(u8, expected, bytes);
        }
    }
};

test "checkpoint rotation preserves data inode and reopens after old WAL collection" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    const inode = (try store.session.replicas[0].data.stat(t.io)).inode;
    try store.write("baseline", 0);
    try store.sync();
    try t.expectEqual(@as(u64, 0), store.session.end);
    try store.collect();
    try store.collect();
    try t.expectError(error.FileNotFound, f.dirs[0].openFile(t.io, "wal-1", .{}));
    try store.write("X", 2);
    store.close();
    store = try f.open();
    defer store.close();
    try f.expect("baXeline");
    try t.expectEqual(inode, (try store.session.replicas[0].data.stat(t.io)).inode);
    try store.sync();
    const sequence = store.session.next;
    try store.sync();
    try t.expectEqual(sequence, store.session.next);
    try store.collect();
}

test "checkpoint refuses WAL-covered corruption on either or both replicas and reopen replays" {
    for ([_]u2{ 1, 2, 3 }) |mask| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write("acknowledged", 0);
        const before = store.checkpoint;
        const log_size = (try store.session.replicas[0].log.stat(t.io)).size;
        for (store.session.replicas, 0..) |replica, i| {
            if (mask & (@as(u2, 1) << @intCast(i)) != 0) try replica.data.writePositionalAll(t.io, "X", 0);
        }
        try t.expectError(error.WalDataMismatch, store.sync());
        try t.expect(std.meta.eql(before, store.checkpoint));
        try t.expectError(error.WalSessionFailed, store.collect());
        for (store.session.replicas) |replica| try t.expectEqual(log_size, (try replica.log.stat(t.io)).size);
        store.close();
        store = try f.open();
        defer store.close();
        try f.expect("acknowledged");
        try store.sync();
    }
}

test "WAL evidence resolves overlaps truncation regrowth and sparse gaps against a byte oracle" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    var expected: [4096]u8 = @splat(0);
    @memset(expected[0..1024], 'B');
    var size: usize = 1024;
    try store.write(expected[0..size], 0);
    try store.sync();
    for (0..1000) |i| {
        if (i % 7 == 0) {
            const length = (i * 137) % expected.len;
            if (length > size) @memset(expected[size..length], 0);
            size = length;
            try store.truncate(size);
        } else {
            const offset = (i * 97) % 4000;
            const length = (i * 31) % 64 + 1;
            if (offset > size) @memset(expected[size..offset], 0);
            @memset(expected[offset..][0..length], @intCast(i % 251));
            size = @max(size, offset + length);
            try store.write(expected[offset..][0..length], offset);
        }
    }
    var bytes: [4096]u8 = undefined;
    for (store.session.replicas) |replica| {
        try t.expectEqual(size, try replica.data.readPositionalAll(t.io, &bytes, 0));
        try t.expectEqualSlices(u8, expected[0..size], bytes[0..size]);
    }
    for ([_]usize{ 0, 3, size / 2, size, size + 10 }) |offset| {
        const count = if (offset >= size) 0 else @min(@as(usize, 17), size - offset);
        try store.verifyRead(offset, if (count == 0) "" else expected[offset..][0..count], 17);
    }
    try store.sync();
}

test "WAL evidence verifies sparse and truncate extension zeros" {
    for ([_]bool{ false, true }) |truncate| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        defer store.close();
        try store.write("baseline", 0);
        try store.sync();
        if (truncate) {
            try store.truncate(2);
            try store.truncate(20);
        } else try store.write("tail", 20);
        for (store.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "X", 10);
        try t.expectError(error.WalDataMismatch, store.sync());
    }
}

test "checkpoint revalidates complete active WALs instead of trusting in-memory sequence" {
    for (0..3) |scenario| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        defer store.close();
        try store.write("payload", 0);
        for (store.session.replicas, 0..) |replica, i| {
            if (scenario == 0) {
                try replica.log.setLength(t.io, store.session.end - 1);
            } else if (scenario == 1 or i == 0) try replica.log.writePositionalAll(t.io, "X", 112);
        }
        const expected = switch (scenario) {
            0 => error.WalChanged,
            1 => error.CorruptWal,
            else => error.WalDiverged,
        };
        try t.expectError(expected, store.sync());
        try t.expectEqual(@as(u64, 1), store.checkpoint.next);
        try t.expectError(error.WalSessionFailed, store.collect());
    }
}

test "WAL verification does not claim evidence for untouched baseline bytes" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    try store.write("baseline", 0);
    try store.sync();
    try store.write("new", 5);
    for (store.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "X", 0);
    try store.sync();
    try f.expect("Xaselnew");
}

test "checkpoint verifies final size even with no pending records" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    for (store.session.replicas) |replica| try replica.data.setLength(t.io, 1);
    try t.expectError(error.WalDataSizeMismatch, store.sync());
}

test "read evidence checks returned bytes rather than rereading healthy files" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    try store.write("abcdefgh", 0);
    try store.verifyRead(2, "cde", 3);
    try t.expectError(error.WalDataMismatch, store.verifyRead(2, "cXe", 3));
    try t.expectError(error.WalSessionFailed, store.sync());
    try f.expect("abcdefgh");
}

test "streaming read verification uses bounded scratch for a large active WAL" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    const payload = try t.allocator.alloc(u8, wal.max_write);
    defer t.allocator.free(payload);
    @memset(payload, 'X');
    for (0..16) |_| try store.write(payload, 0);
    try t.expect(store.session.end > 16 * 1024 * 1024);
    // The former whole-log reader cannot fit even one log in this allocator.
    const scratch = try t.allocator.alloc(u8, 4 * 1024 * 1024);
    defer t.allocator.free(scratch);
    var bounded = std.heap.FixedBufferAllocator.init(scratch);
    store.session.allocator = bounded.allocator();
    defer store.session.allocator = t.allocator;
    try store.verifyRead(123, "X", 1);
    try store.verifyRead(0, payload, payload.len);
    try store.verifyRead(payload.len, "", 16);
    try store.verifyRead(0, "", 0);
}

test "streaming verification rechecks WAL corruption outside the read window" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    try store.write("first", 0);
    try store.write("other", 100);
    try store.verifyRead(0, "first", 5);
    for (store.session.replicas) |replica| try replica.log.writePositionalAll(t.io, "Q", 112 + 5 + 112);
    try t.expectError(error.CorruptWal, store.verifyRead(0, "first", 5));
    try t.expectError(error.WalSessionFailed, store.collect());
    try t.expectEqual(@as(u64, 1), store.checkpoint.next);
}

test "streaming verification rejects a one-sided final payload byte outside the read window" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    const payload = try t.allocator.alloc(u8, wal.max_write);
    defer t.allocator.free(payload);
    @memset(payload, 'X');
    try store.write(payload, 0);
    try store.verifyRead(0, "X", 1);
    try store.session.replicas[1].log.writePositionalAll(t.io, "Y", 112 + payload.len - 1);
    try t.expectError(error.WalDiverged, store.verifyRead(0, "X", 1));
    try t.expectError(error.WalSessionFailed, store.collect());
    try t.expectEqual(@as(u64, 1), store.checkpoint.next);
}

test "streaming WAL frame length is authenticated and bounded before payload reads" {
    for ([_]u32{ wal.max_write, wal.max_write + 1 }) |length| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        defer store.close();
        try store.write("abc", 0);
        for (store.session.replicas) |replica| {
            var header: [112]u8 = undefined;
            try t.expectEqual(header.len, try replica.log.readPositionalAll(t.io, &header, 0));
            std.mem.writeInt(u32, header[40..44], length, .little);
            std.crypto.hash.sha2.Sha256.hash(header[0..80], header[80..112], .{});
            try replica.log.writePositionalAll(t.io, &header, 0);
        }
        try t.expectError(if (length == wal.max_write) error.WalChanged else error.CorruptWal, store.verifyRead(0, "abc", 3));
    }
}

test "sealed baseline repairs either replica in place and preserves the source" {
    for (0..2) |bad| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write("baseline", 0);
        try store.establishSeal();
        const next = store.checkpoint.next;
        const inode = (try store.session.replicas[bad].data.stat(t.io)).inode;
        try store.session.replicas[bad].data.writePositionalAll(t.io, "broken-longer", 0);
        store.close();
        try t.expectError(error.SealedContentMismatch, f.open());
        store = try files.Store.openMode(t.allocator, t.io, identity, f.dirs, next);
        defer store.close();
        try f.expect("baseline");
        try t.expectEqual(inode, (try store.session.replicas[bad].data.stat(t.io)).inode);
        try t.expectEqual(next, store.checkpoint.next);
        try t.expect(store.seal != null);
    }
}

test "explicit sealed repair recreates only a missing data file and preserves all evidence" {
    for (0..2) |missing| for ([_][]const u8{ "", "sealed baseline" }) |content| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write(content, 0);
        try store.establishSeal();
        const baseline = store.seal.?;
        const source_inode = (try store.session.replicas[1 - missing].data.stat(t.io)).inode;
        const checkpoint = try f.dirs[missing].readFileAlloc(t.io, "checkpoint", t.allocator, .limited(128));
        defer t.allocator.free(checkpoint);
        store.close();
        try f.dirs[missing].deleteFile(t.io, "data");
        try t.expectError(error.FileNotFound, f.open());
        try t.expectError(error.FileNotFound, f.dirs[missing].openFile(t.io, "data", .{}));
        store = try files.Store.openMode(t.allocator, t.io, identity, f.dirs, baseline.next);
        try f.expect(content);
        try t.expectEqual(source_inode, (try store.session.replicas[1 - missing].data.stat(t.io)).inode);
        try t.expectEqualDeep(baseline, store.seal.?);
        const target_inode = (try store.session.replicas[missing].data.stat(t.io)).inode;
        store.close();
        store = try f.open();
        defer store.close();
        try t.expectEqual(target_inode, (try store.session.replicas[missing].data.stat(t.io)).inode);
        for (f.dirs) |dir| {
            const after = try dir.readFileAlloc(t.io, "checkpoint", t.allocator, .limited(128));
            defer t.allocator.free(after);
            try t.expectEqualSlices(u8, checkpoint, after);
            try t.expectEqualDeep(baseline, (try Seal.read(t.io, dir, identity)).?);
        }
    };
}

test "missing data rebuild refuses incomplete evidence and unverified sources before creation" {
    const Damage = enum { checkpoint, seal, log, pending, source, both, corrupt_seal, stale };
    for (std.meta.tags(Damage)) |damage| for (0..2) |missing| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write("baseline", 0);
        try store.establishSeal();
        const next = store.checkpoint.next;
        store.close();
        try f.dirs[missing].deleteFile(t.io, "data");
        var name_buffer: [32]u8 = undefined;
        const log_name = try std.fmt.bufPrint(&name_buffer, "wal-{d}", .{next});
        switch (damage) {
            .checkpoint => try f.dirs[missing].deleteFile(t.io, "checkpoint"),
            .seal => try f.dirs[missing].deleteFile(t.io, "seal"),
            .log => try f.dirs[missing].deleteFile(t.io, log_name),
            .both => try f.dirs[1 - missing].deleteFile(t.io, "data"),
            .pending, .source, .corrupt_seal => {
                const dir = f.dirs[if (damage == .source) 1 - missing else missing];
                const file = try dir.openFile(t.io, if (damage == .source) "data" else if (damage == .pending) log_name else "seal", .{ .mode = .read_write });
                defer file.close(t.io);
                try file.writePositionalAll(t.io, "X", 0);
            },
            .stale => {},
        }
        const expected = switch (damage) {
            .checkpoint => error.CheckpointDiverged,
            .seal => error.MissingSeal,
            .log => error.FileNotFound,
            .pending => error.SealWithPendingWal,
            .source, .both => error.NoVerifiedReplica,
            .corrupt_seal => error.CorruptSeal,
            .stale => error.StaleFileState,
        };
        try t.expectError(expected, files.Store.openMode(t.allocator, t.io, identity, f.dirs, next + @intFromBool(damage == .stale)));
        try t.expectError(error.FileNotFound, f.dirs[missing].openFile(t.io, "data", .{}));
        if (damage != .both) {
            const bytes = try f.dirs[1 - missing].readFileAlloc(t.io, "data", t.allocator, .limited(64));
            defer t.allocator.free(bytes);
            try t.expectEqualStrings(if (damage == .source) "Xaseline" else "baseline", bytes);
        }
    };
}

test "missing file repair cannot bypass a live owner through a replacement inode" {
    for ([_]bool{ false, true }) |log| for (0..2) |missing| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        defer store.close();
        try store.write("baseline", 0);
        try store.establishSeal();
        var buffer: [32]u8 = undefined;
        const name = if (log) try std.fmt.bufPrint(&buffer, "wal-{d}", .{store.checkpoint.next}) else "data";
        try f.dirs[missing].deleteFile(t.io, name);
        try t.expectError(error.FileBusy, files.Store.openMode(t.allocator, t.io, identity, f.dirs, store.checkpoint.next));
        try t.expectError(error.FileNotFound, f.dirs[missing].openFile(t.io, name, .{}));
    };
}

test "explicit repair recreates one missing empty WAL only from complete sealed data" {
    for (0..2) |missing| for ([_][]const u8{ "", "sealed baseline" }) |content| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write(content, 0);
        try store.establishSeal();
        const baseline = store.seal.?;
        const inodes = [2]u64{ (try store.session.replicas[0].data.stat(t.io)).inode, (try store.session.replicas[1].data.stat(t.io)).inode };
        const source_log_inode = (try store.session.replicas[1 - missing].log.stat(t.io)).inode;
        const checkpoint = try f.dirs[missing].readFileAlloc(t.io, "checkpoint", t.allocator, .limited(128));
        defer t.allocator.free(checkpoint);
        store.close();
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "wal-{d}", .{baseline.next});
        try f.dirs[missing].deleteFile(t.io, name);
        try t.expectError(error.FileNotFound, f.open());
        try t.expectError(error.FileNotFound, f.dirs[missing].openFile(t.io, name, .{}));
        store = try files.Store.openMode(t.allocator, t.io, identity, f.dirs, baseline.next);
        try f.expect(content);
        for (store.session.replicas, inodes) |replica, inode| {
            try t.expectEqual(inode, (try replica.data.stat(t.io)).inode);
            try t.expectEqual(@as(u64, 0), (try replica.log.stat(t.io)).size);
        }
        try t.expectEqual(source_log_inode, (try store.session.replicas[1 - missing].log.stat(t.io)).inode);
        const new_inode = (try store.session.replicas[missing].log.stat(t.io)).inode;
        store.close();
        store = try files.Store.openMode(t.allocator, t.io, identity, f.dirs, baseline.next);
        defer store.close();
        try t.expectEqual(new_inode, (try store.session.replicas[missing].log.stat(t.io)).inode);
        for (f.dirs) |dir| {
            const after = try dir.readFileAlloc(t.io, "checkpoint", t.allocator, .limited(128));
            defer t.allocator.free(after);
            try t.expectEqualSlices(u8, checkpoint, after);
            try t.expectEqualDeep(baseline, (try Seal.read(t.io, dir, identity)).?);
        }
    };
}

test "missing WAL reconstruction refuses incomplete evidence or damaged data without mutation" {
    const Damage = enum { checkpoint, seal, seals, pending, data, missing_data, both, stale, corrupt_seal };
    for (std.meta.tags(Damage)) |damage| for (0..2) |missing| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write("baseline", 0);
        try store.establishSeal();
        const next = store.checkpoint.next;
        store.close();
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "wal-{d}", .{next});
        try f.dirs[missing].deleteFile(t.io, name);
        switch (damage) {
            .checkpoint => try f.dirs[missing].deleteFile(t.io, "checkpoint"),
            .seal => try f.dirs[missing].deleteFile(t.io, "seal"),
            .seals => for (f.dirs) |dir| try dir.deleteFile(t.io, "seal"),
            .missing_data => try f.dirs[missing].deleteFile(t.io, "data"),
            .both => try f.dirs[1 - missing].deleteFile(t.io, name),
            .pending, .data, .corrupt_seal => {
                const dir = f.dirs[if (damage == .pending) 1 - missing else missing];
                const file = try dir.openFile(t.io, if (damage == .data) "data" else if (damage == .pending) name else "seal", .{ .mode = .read_write });
                defer file.close(t.io);
                try file.writePositionalAll(t.io, "X", 0);
            },
            .stale => {},
        }
        const expected = switch (damage) {
            .checkpoint => error.CheckpointDiverged,
            .seal, .seals => error.MissingSeal,
            .missing_data, .both => error.FileNotFound,
            .pending => error.SealWithPendingWal,
            .data => error.SealedContentMismatch,
            .corrupt_seal => error.CorruptSeal,
            .stale => error.StaleFileState,
        };
        try t.expectError(expected, files.Store.openMode(t.allocator, t.io, identity, f.dirs, next + @intFromBool(damage == .stale)));
        try t.expectError(error.FileNotFound, f.dirs[missing].openFile(t.io, name, .{}));
        if (damage != .missing_data) {
            const bytes = try f.dirs[missing].readFileAlloc(t.io, "data", t.allocator, .limited(64));
            defer t.allocator.free(bytes);
            try t.expectEqualStrings(if (damage == .data) "Xaseline" else "baseline", bytes);
        }
    };
}

test "explicit repair restores one seal only after verifying both complete replicas" {
    for (0..2) |missing| for ([_][]const u8{ "", "baseline" }) |content| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write(content, 0);
        try store.establishSeal();
        const baseline = store.seal.?;
        const inodes = [2]u64{ (try store.session.replicas[0].data.stat(t.io)).inode, (try store.session.replicas[1].data.stat(t.io)).inode };
        store.close();
        try f.dirs[missing].deleteFile(t.io, "seal");
        store = try f.open();
        store.close();
        try t.expectEqual(null, try Seal.read(t.io, f.dirs[missing], identity));
        const source = try f.dirs[1 - missing].openFile(t.io, "seal", .{});
        defer source.close(t.io);
        const source_inode = (try source.stat(t.io)).inode;
        store = try files.Store.openMode(t.allocator, t.io, identity, f.dirs, baseline.next);
        store.close();
        const restored = try f.dirs[missing].openFile(t.io, "seal", .{});
        defer restored.close(t.io);
        const restored_inode = (try restored.stat(t.io)).inode;
        store = try files.Store.openMode(t.allocator, t.io, identity, f.dirs, baseline.next);
        defer store.close();
        for (f.dirs, store.session.replicas, inodes, 0..) |dir, replica, inode, i| {
            try t.expectEqualDeep(baseline, (try Seal.read(t.io, dir, identity)).?);
            try t.expectEqual(inode, (try replica.data.stat(t.io)).inode);
            const file = try dir.openFile(t.io, "seal", .{});
            defer file.close(t.io);
            try t.expectEqual(if (i == missing) restored_inode else source_inode, (try file.stat(t.io)).inode);
        }
        try f.expect(content);
        try store.write("resumed", 0);
        try store.sync();
    };
}

test "missing seal reconstruction refuses damaged data and incomplete checkpoints" {
    for (0..2) |missing| for (0..6) |damage| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write("baseline", 0);
        try store.establishSeal();
        const next = store.checkpoint.next;
        store.close();
        try f.dirs[missing].deleteFile(t.io, "seal");
        if (damage < 2) {
            const file = try f.dirs[damage].openFile(t.io, "data", .{ .mode = .read_write });
            defer file.close(t.io);
            try file.writePositionalAll(t.io, "X", 0);
        } else if (damage == 2) {
            try f.dirs[missing].deleteFile(t.io, "checkpoint");
        } else if (damage == 3) {
            var buffer: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&buffer, "wal-{d}", .{next});
            const file = try f.dirs[missing].openFile(t.io, name, .{ .mode = .read_write });
            defer file.close(t.io);
            try file.writePositionalAll(t.io, "X", 0);
        } else if (damage == 4) {
            try f.dirs[1 - missing].deleteFile(t.io, "seal");
        }
        const expected = switch (damage) {
            0, 1 => error.SealedContentMismatch,
            2 => error.CheckpointDiverged,
            3 => error.SealWithPendingWal,
            4 => error.MissingSeal,
            else => error.StaleFileState,
        };
        try t.expectError(expected, files.Store.openMode(t.allocator, t.io, identity, f.dirs, next + @intFromBool(damage == 5)));
        try t.expectEqual(null, try Seal.read(t.io, f.dirs[missing], identity));
        for (f.dirs, 0..) |dir, i| {
            const bytes = try dir.readFileAlloc(t.io, "data", t.allocator, .limited(64));
            defer t.allocator.free(bytes);
            try t.expectEqualStrings(if (i == damage) "Xaseline" else "baseline", bytes);
        }
    };
}

test "sealed identical corruption is rejected and cannot be resealed or repaired" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try store.write("baseline", 0);
    try store.establishSeal();
    for (store.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "X", 0);
    try t.expectError(error.SealedContentMismatch, store.establishSeal());
    store.close();
    try t.expectError(error.SealedContentMismatch, f.open());
    try t.expectError(error.NoVerifiedReplica, files.Store.openMode(t.allocator, t.io, identity, f.dirs, 1));
    try f.expect("Xaseline");
}

test "write and truncate invalidate both seals before redo and survive reopen" {
    for ([_]bool{ false, true }) |truncate| {
        var f = try Fixture.init();
        defer f.deinit();
        var store = try f.create();
        try store.write("baseline", 0);
        try store.establishSeal();
        if (truncate) try store.truncate(2) else try store.write("X", 0);
        for (f.dirs) |dir| try t.expect(try Seal.read(t.io, dir, identity) == null);
        store.close();
        store = try f.open();
        defer store.close();
        try t.expect(store.seal == null);
        try f.expect(if (truncate) "ba" else "Xaseline");
    }
}

test "partial seal publication or invalidation leaves a usable baseline" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try store.write("baseline", 0);
    try store.establishSeal();
    store.close();
    // The same on-disk state occurs after first publication or first unlink.
    try f.dirs[0].deleteFile(t.io, "seal");
    store = try f.open();
    try t.expect(store.seal != null);
    try store.write("X", 0);
    store.close();
    for (f.dirs) |dir| try t.expect(try Seal.read(t.io, dir, identity) == null);
    store = try f.open();
    defer store.close();
    try f.expect("Xaseline");
}

test "failed seal invalidation does not append WAL or modify either data file" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    try store.write("baseline", 0);
    try store.establishSeal();
    try f.dirs[1].rename("seal", f.dirs[1], "saved-seal", t.io);
    try f.dirs[1].createDir(t.io, "seal", .default_dir);
    if (store.write("X", 0)) |_| return error.ExpectedFailure else |_| {}
    try t.expect(store.session.failed);
    for (store.session.replicas) |replica| try t.expectEqual(@as(u64, 0), (try replica.log.stat(t.io)).size);
    try f.expect("baseline");
}

test "repair requires a valid seal, matching identity and nonstale sequence" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    store.close();
    try t.expectError(error.MissingSeal, files.Store.openMode(t.allocator, t.io, identity, f.dirs, 1));
    store = try f.open();
    try store.establishSeal();
    const baseline = store.seal.?;
    store.close();
    try t.expectError(error.StaleFileState, files.Store.openMode(t.allocator, t.io, identity, f.dirs, baseline.next + 1));
    try baseline.publish(t.io, f.dirs[0], .{ .inode = identity.inode, .generation = identity.generation + 1 });
    try t.expectError(error.SealIdentityMismatch, f.open());
    var stale = baseline;
    stale.next += 1;
    for (f.dirs) |dir| try stale.publish(t.io, dir, identity);
    try t.expectError(error.StaleSeal, f.open());
    try baseline.publish(t.io, f.dirs[0], identity);
    try t.expectError(error.SealDiverged, f.open());
    const seal = try f.dirs[0].openFile(t.io, "seal", .{ .mode = .read_write });
    defer seal.close(t.io);
    try seal.writePositionalAll(t.io, "X", 40);
    try t.expectError(error.CorruptSeal, f.open());
}

test "pending WAL cannot coexist with a valid seal and partial repairs are retryable" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try store.write("baseline", 0);
    try store.establishSeal();
    const baseline = store.seal.?;
    // Simulate an interrupted in-place repair: the source and seal are intact.
    try store.session.replicas[1].data.setLength(t.io, 3);
    store.close();
    store = try files.Store.openMode(t.allocator, t.io, identity, f.dirs, baseline.next);
    try f.expect("baseline");
    try store.write("X", 0);
    store.close();
    // An obsolete writer or external restore must not silently reactivate a seal.
    for (f.dirs) |dir| try baseline.publish(t.io, dir, identity);
    try t.expectError(error.SealWithPendingWal, f.open());
}

test "checkpoint recovery adopts one published higher checkpoint without replaying old truncates" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    const old = try f.dirs[1].readFileAlloc(t.io, "checkpoint", t.allocator, .limited(128));
    defer t.allocator.free(old);
    try store.write("old", 0);
    try store.truncate(1);
    try store.write("updated", 0);
    try store.sync();
    // Model death between the two atomic checkpoint publications.
    const checkpoint = try f.dirs[1].createFile(t.io, "checkpoint", .{});
    try checkpoint.writePositionalAll(t.io, old, 0);
    checkpoint.close(t.io);
    store.close();
    store = try f.open();
    defer store.close();
    try f.expect("updated");
    try t.expectEqual(@as(u64, 0), store.session.end);
    try store.collect();
    try store.write("!", 7);
    try store.sync();
    try f.expect("updated!");
}

test "unpublished empty next WAL is reusable and missing active WAL is never recreated" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try store.write("data", 0);
    const orphan = try f.dirs[0].createFile(t.io, "wal-2", .{});
    orphan.close(t.io);
    store.close();
    store = try f.open();
    try store.sync();
    store.close();
    try f.dirs[1].deleteFile(t.io, "wal-2");
    try t.expectError(error.FileNotFound, f.open());
    try t.expectError(error.FileNotFound, f.dirs[1].openFile(t.io, "wal-2", .{}));
    try f.expect("data");
}

test "data ownership excludes another opener and wrong identity cannot open checkpoint" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try t.expectError(error.FileBusy, f.open());
    store.close();
    try t.expectError(error.WalIdentityMismatch, files.Store.open(t.allocator, t.io, .{ .inode = 42, .generation = 10 }, f.dirs));
    store = try f.open();
    store.close();
}

test "checkpoint corruption fails closed and cannot authorize collection" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try store.write("data", 0);
    try store.sync();
    const checkpoint = try f.dirs[1].openFile(t.io, "checkpoint", .{ .mode = .read_write });
    try checkpoint.writePositionalAll(t.io, "!", 32);
    checkpoint.close(t.io);
    try t.expectError(error.CorruptCheckpoint, store.collect());
    const old = try f.dirs[0].openFile(t.io, "wal-1", .{});
    old.close(t.io);
    store.close();
    try t.expectError(error.CorruptCheckpoint, f.open());
    try f.expect("data");
}

test "partial checkpoint publication freezes then converges before reclaiming old logs" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try store.write("durable", 0);
    try f.dirs[1].rename("checkpoint", f.dirs[1], "saved", t.io);
    try f.dirs[1].createDir(t.io, "checkpoint", .default_dir);
    var failed = false;
    store.sync() catch {
        failed = true;
    };
    try t.expect(failed);
    try t.expectError(error.WalSessionFailed, store.write("later", 0));
    try t.expectError(error.WalSessionFailed, store.collect());
    // Successful side must already have finished publication before sync returned.
    const checkpoint = try f.dirs[0].readFileAlloc(t.io, "checkpoint", t.allocator, .limited(128));
    defer t.allocator.free(checkpoint);
    try t.expectEqual(@as(u64, 2), std.mem.readInt(u64, checkpoint[24..32], .little));
    store.close();
    try f.dirs[1].deleteDir(t.io, "checkpoint");
    try f.dirs[1].rename("saved", f.dirs[1], "checkpoint", t.io);
    store = try f.open();
    defer store.close();
    try f.expect("durable");
    try store.collect();
    try store.write("!", 7);
    try store.sync();
    try f.expect("durable!");
}

test "checkpoint recovery tolerates partial old-log reclamation" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    try store.write("data", 0);
    try store.sync();
    try f.dirs[0].deleteFile(t.io, "wal-1");
    store.close();
    store = try f.open();
    defer store.close();
    try store.collect();
    try f.expect("data");
    try t.expectError(error.FileNotFound, f.dirs[1].openFile(t.io, "wal-1", .{}));
}

test "nonempty orphan next WAL cannot be reused or deleted" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    defer store.close();
    try store.write("data", 0);
    const orphan = try f.dirs[0].createFile(t.io, "wal-2", .{});
    try orphan.writePositionalAll(t.io, "unexpected", 0);
    orphan.close(t.io);
    try t.expectError(error.UnexpectedWal, store.sync());
    try t.expect(store.session.failed);
    const bytes = try f.dirs[0].readFileAlloc(t.io, "wal-2", t.allocator, .limited(128));
    defer t.allocator.free(bytes);
    try t.expectEqualSlices(u8, "unexpected", bytes);
}

test "missing checkpoint after initialization can be restored but missing baseline cannot" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    store.close();
    try f.dirs[1].deleteFile(t.io, "checkpoint");
    store = try f.open();
    try store.write("data", 0);
    try store.sync();
    store.close();
    const data = try f.dirs[1].openFile(t.io, "data", .{ .mode = .read_write });
    try data.setLength(t.io, 0);
    data.close(t.io);
    try t.expectError(error.ReplicaSizeMismatch, f.open());
}

test "WAL capacity rotates epochs instead of imposing a lifetime write limit" {
    var f = try Fixture.init();
    defer f.deinit();
    var store = try f.create();
    const buffer = try t.allocator.alloc(u8, wal.max_write);
    defer t.allocator.free(buffer);
    const inode = (try store.session.replicas[0].data.stat(t.io)).inode;
    for (0..65) |i| {
        @memset(buffer, @intCast(i));
        try store.write(buffer, 0);
    }
    try t.expect(store.session.end < wal.max_log);
    try store.sync();
    try store.collect();
    store.close();
    store = try f.open();
    defer store.close();
    try t.expectEqual(inode, (try store.session.replicas[0].data.stat(t.io)).inode);
    for (store.session.replicas) |replica| {
        try t.expectEqual(@as(u64, wal.max_write), (try replica.data.stat(t.io)).size);
        try t.expectEqual(buffer.len, try replica.data.readPositionalAll(t.io, buffer, 0));
        for (buffer) |byte| try t.expectEqual(@as(u8, 64), byte);
    }
}
