const std = @import("std");
const t = std.testing;
const files = @import("file_store.zig");
const wal = @import("file_wal.zig");
const identity: wal.Identity = .{ .inode = 42, .generation = 9 };

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
