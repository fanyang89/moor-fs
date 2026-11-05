const std = @import("std");
const t = std.testing;
const wal = @import("file_wal.zig");
const identity: wal.Identity = .{ .inode = 2, .generation = 7 };

const Fixture = struct {
    tmp: t.TmpDir,
    replicas: [2]wal.Replica,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var replicas: [2]wal.Replica = undefined;
        var count: usize = 0;
        errdefer for (replicas[0..count]) |r| {
            r.log.close(t.io);
            r.data.close(t.io);
        };
        for ([_][]const u8{ "a", "b" }, [_][]const u8{ "a.wal", "b.wal" }) |data_name, log_name| {
            const data = try tmp.dir.createFile(t.io, data_name, .{ .read = true });
            errdefer data.close(t.io);
            const log = try tmp.dir.createFile(t.io, log_name, .{ .read = true });
            replicas[count] = .{ .data = data, .log = log };
            count += 1;
        }
        return .{ .tmp = tmp, .replicas = replicas };
    }

    fn deinit(self: *Fixture) void {
        for (self.replicas) |r| {
            r.log.close(t.io);
            r.data.close(t.io);
        }
        self.tmp.cleanup();
    }

    fn recover(self: *Fixture) !wal.Session {
        return wal.Session.recover(t.allocator, t.io, identity, self.replicas);
    }

    fn expect(self: *Fixture, bytes: []const u8) !void {
        for (self.replicas) |r| {
            try t.expectEqual(bytes.len, (try r.data.stat(t.io)).size);
            const actual = try t.allocator.alloc(u8, bytes.len);
            defer t.allocator.free(actual);
            try t.expectEqual(bytes.len, try r.data.readPositionalAll(t.io, actual, 0));
            try t.expectEqualSlices(u8, bytes, actual);
        }
    }
};

test "WAL sparse writes truncate and repeated recovery preserve complete files" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    try session.write("abcdef", 0);
    try session.truncate(2);
    try session.truncate(8);
    try session.write("Z", 6);
    try session.sync();
    try f.expect("ab\x00\x00\x00\x00Z\x00");
    const end = session.end;
    for (0..2) |_| {
        session = try f.recover();
        try t.expectEqual(end, session.end);
        try f.expect("ab\x00\x00\x00\x00Z\x00");
    }
    try session.write("Q", 1);
    try f.expect("aQ\x00\x00\x00\x00Z\x00");
}

test "WAL recovery repairs one-sided log and unapplied data before new writes" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    try session.write("first", 0);
    const boundary = session.end;
    try session.write("second", 5);
    // Model death after only one complete WAL append and before data application.
    try f.replicas[1].log.setLength(t.io, boundary + 17);
    for (f.replicas) |r| try r.data.setLength(t.io, 0);
    session = try f.recover();
    try f.expect("firstsecond");
    try t.expectEqual(session.end, (try f.replicas[1].log.stat(t.io)).size);
    // Model death after only the first data replica changed.
    try f.replicas[1].data.setLength(t.io, 0);
    _ = try f.recover();
    try f.expect("firstsecond");
}

test "WAL discards an incomplete common tail but rejects complete corruption" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    try session.write("stable", 0);
    const end = session.end;
    try session.write("pending", 6);
    for (f.replicas) |r| {
        try r.log.setLength(t.io, end + 115);
        try r.data.setLength(t.io, 6);
    }
    session = try f.recover();
    try t.expectEqual(end, session.end);
    try f.expect("stable");
    try f.replicas[1].log.writePositionalAll(t.io, "!", 112);
    try t.expectError(error.CorruptWal, f.recover());
    try f.expect("stable");
}

test "WAL rejects wrong identity and divergent valid histories without data mutation" {
    var a = try Fixture.init();
    defer a.deinit();
    var b = try Fixture.init();
    defer b.deinit();
    var sa = try a.recover();
    var sb = try b.recover();
    try sa.write("AAA", 0);
    try sb.write("BBB", 0);
    try t.expectError(error.WalIdentityMismatch, wal.Session.recover(t.allocator, t.io, .{ .inode = 2, .generation = 8 }, a.replicas));
    try t.expectError(error.WalDiverged, wal.Session.recover(t.allocator, t.io, identity, .{ a.replicas[0], b.replicas[1] }));
    try a.expect("AAA");
    try b.expect("BBB");
}

test "small WAL updates retain data inodes and only append changed bytes" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    try session.truncate(16 * 1024 * 1024);
    const before = try f.replicas[0].data.stat(t.io);
    const log_before = session.end;
    for (0..3) |_| {
        try session.write("x", 1024);
        try session.sync();
    }
    const after = try f.replicas[0].data.stat(t.io);
    try t.expectEqual(before.inode, after.inode);
    try t.expectEqual(before.size, after.size);
    try t.expectEqual(@as(u64, 3 * 113), session.end - log_before);
}

test "WAL append error joins the peer and freezes before touching either data file" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    const readonly = try f.tmp.dir.openFile(t.io, "a.wal", .{});
    defer readonly.close(t.io);
    session.replicas[0].log = readonly;
    var failed = false;
    session.write("pending", 0) catch {
        failed = true;
    };
    try t.expect(failed);
    try t.expect(session.failed);
    try t.expectError(error.WalSessionFailed, session.write("later", 0));
    try t.expectError(error.WalSessionFailed, session.sync());
    try f.expect("");
    try t.expectEqual(@as(u64, 119), (try f.replicas[1].log.stat(t.io)).size);
    _ = try f.recover();
    try f.expect("pending");
}

test "WAL data error joins the peer and recovery repairs the incomplete write" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    const readonly = try f.tmp.dir.openFile(t.io, "a", .{});
    defer readonly.close(t.io);
    session.replicas[0].data = readonly;
    var failed = false;
    session.write("recover", 0) catch {
        failed = true;
    };
    try t.expect(failed);
    try t.expect(session.failed);
    try t.expectEqual(@as(u64, 0), (try f.replicas[0].data.stat(t.io)).size);
    try t.expectEqual(@as(u64, 7), (try f.replicas[1].data.stat(t.io)).size);
    _ = try f.recover();
    try f.expect("recover");
}

test "WAL length corruption cannot masquerade as a torn payload" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    try session.write("safe", 0);
    try f.replicas[0].log.writePositionalAll(t.io, &.{100}, 40);
    try t.expectError(error.CorruptWal, f.recover());
    try f.expect("safe");
}

test "every byte cut in one WAL tail is recovered from the complete peer" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.recover();
    try session.write("base", 0);
    const boundary = session.end;
    try session.write("next", 4);
    const end = session.end;
    var cut = boundary;
    while (cut < end) : (cut += 1) {
        try f.replicas[1].log.setLength(t.io, cut);
        try f.replicas[1].data.setLength(t.io, 4);
        session = try f.recover();
        try t.expectEqual(end, session.end);
        try f.expect("basenext");
    }
}

test "WAL partial updates preserve baseline bytes absent from the log" {
    var f = try Fixture.init();
    defer f.deinit();
    for (f.replicas) |r| try r.data.writePositionalAll(t.io, "baseline", 0);
    var session = try f.recover();
    try session.write("X", 3);
    _ = try f.recover();
    try f.expect("basXline");
    try t.expectError(error.InvalidRange, session.write("xx", std.math.maxInt(i64)));
    try t.expect(!session.failed);
    const end = session.end;
    session.end = wal.max_log;
    try t.expectError(error.WalCapacityExceeded, session.write("x", 0));
    try t.expect(!session.failed);
    for (f.replicas) |r| try t.expectEqual(end, (try r.log.stat(t.io)).size);
}
