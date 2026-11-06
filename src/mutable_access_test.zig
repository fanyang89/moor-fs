const std = @import("std");
const t = std.testing;
const access = @import("mutable_access.zig");
const objects = @import("objects.zig");
const m = @import("metadata.zig");

const Metadata = struct {
    state: m.State,
    lose_reply: bool = false,
    unavailable: bool = false,
    conflict: bool = false,

    fn api(self: *Metadata) access.Metadata {
        return .{ .context = self, .get = get, .version = version, .backend = backend, .apply = apply };
    }

    fn get(ctx: *anyopaque, id: u64) !access.Head {
        const self: *Metadata = @ptrCast(@alignCast(ctx));
        if (self.unavailable) return error.ClusterUnavailable;
        return access.Head.from(self.state.get(id) orelse return error.NotFound);
    }

    fn version(ctx: *anyopaque, id: u64) !m.Version {
        const self: *Metadata = @ptrCast(@alignCast(ctx));
        for (self.state.versions.items) |v| if (v.id == id) return v;
        return error.NotFound;
    }

    fn backend(ctx: *anyopaque, id: u64) !m.Backend {
        const self: *Metadata = @ptrCast(@alignCast(ctx));
        for (self.state.backends.items) |b| if (b.id == id) return b;
        return error.BackendNotFound;
    }

    fn apply(ctx: *anyopaque, request: m.Request) !m.Result {
        const self: *Metadata = @ptrCast(@alignCast(ctx));
        if (self.unavailable) return error.ClusterUnavailable;
        if (self.conflict) return .{ .status = .sequence_conflict };
        const result = try self.state.apply(request);
        if (self.lose_reply) {
            self.lose_reply = false;
            return error.ReplyLost;
        }
        return result;
    }
};

const Fixture = struct {
    tmp: t.TmpDir,
    mappings: [2]objects.Mapping,
    meta: Metadata,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var state = try m.State.init(t.allocator);
        errdefer state.deinit();
        _ = try state.apply(.{ .request_id = 1, .command = .{ .create = .{ .parent = 1, .name = "file", .kind = .file } } });
        var mappings: [2]objects.Mapping = undefined;
        var count: usize = 0;
        errdefer for (mappings[0..count]) |mapping| t.allocator.free(mapping.root);
        for ([_][]const u8{ "a", "b" }, 0..) |name, i| {
            try tmp.dir.createDir(t.io, name, .default_dir);
            const path = try tmp.dir.realPathFileAlloc(t.io, name, t.allocator);
            defer t.allocator.free(path);
            mappings[i] = .{ .id = i + 1, .root = try t.allocator.dupe(u8, path), .allow_local = true };
            count += 1;
            const store = try objects.Store.openMapping(t.io, mappings[i], true);
            store.close();
            _ = try state.apply(.{ .request_id = i + 2, .command = .{ .register_backend = .{ .id = i + 1, .failure_domain = i + 10 } } });
        }
        return .{ .tmp = tmp, .mappings = mappings, .meta = .{ .state = state } };
    }

    fn deinit(self: *Fixture) void {
        self.meta.state.deinit();
        for (self.mappings) |mapping| t.allocator.free(mapping.root);
        self.tmp.cleanup();
    }

    fn open(self: *Fixture) !access.Access {
        return access.Access.open(t.allocator, t.io, self.meta.api(), &self.mappings, 2, .{ 1, 2 });
    }

    fn seed(self: *Fixture, bytes: []const u8) !m.Version {
        const source = try self.tmp.dir.createFile(t.io, "source", .{ .read = true });
        defer source.close(t.io);
        try source.writePositionalAll(t.io, bytes, 0);
        const digest = try objects.hash(t.io, source);
        const version: m.Version = .{ .id = 10, .inode = 2, .size = bytes.len, .sha256 = digest.sha256, .backends = .{ 1, 2 } };
        for (self.mappings) |mapping| {
            const store = try objects.Store.openMapping(t.io, mapping, false);
            defer store.close();
            try store.put(source, version);
        }
        _ = try self.meta.state.apply(.{ .request_id = 4, .command = .{ .publish = .{ .expected_version = 0, .version = version } } });
        return version;
    }
};

test "file service isolates connection handles and shares live writes across owners" {
    var f = try Fixture.init();
    defer f.deinit();
    var service: @import("file_service.zig").Service = .{
        .allocator = t.allocator,
        .io = t.io,
        .metadata = f.meta.api(),
        .mappings = &f.mappings,
        .migration_pair = .{ 1, 2 },
    };
    defer service.deinit();
    const a = try service.connect();
    const b = try service.connect();
    const writer = try service.open(a, 2, true);
    const reader = try service.open(b, 2, false);
    try t.expectError(error.FileBusy, service.open(b, 2, true));
    try t.expectError(error.InvalidHandle, service.write(b, writer.handle, "bad", 0));
    try t.expectError(error.InvalidHandle, service.close(a, reader.handle));
    try t.expectError(error.ReadOnlyHandle, service.write(b, reader.handle, "bad", 0));
    try service.write(a, writer.handle, "shared", 0);
    var buffer: [16]u8 = undefined;
    const count = try service.read(b, reader.handle, &buffer, 0);
    try t.expectEqualStrings("shared", buffer[0..count]);
    try t.expectEqual(@as(u64, 6), try service.size(b, reader.handle));
    service.disconnect(a);
    try t.expectError(error.InvalidConnection, service.open(a, 2, false));
    try t.expectError(error.InvalidHandle, service.size(a, writer.handle));
    const replacement = try service.open(b, 2, true);
    try service.truncate(b, replacement.handle, 3);
    try t.expectEqual(@as(u64, 3), try service.size(b, reader.handle));
    try service.close(b, replacement.handle);
    try service.close(b, reader.handle);
    try t.expectEqual(@as(u32, 0), service.sessions.count());
    var reopened = try f.open();
    defer reopened.close();
    try t.expectEqual(@as(usize, 3), try reopened.read(&buffer, 0));
    try t.expectEqualStrings("sha", buffer[0..3]);
}

test "file service disconnect recovers WAL and failed close preserves frozen readers" {
    var f = try Fixture.init();
    defer f.deinit();
    var service: @import("file_service.zig").Service = .{
        .allocator = t.allocator,
        .io = t.io,
        .metadata = f.meta.api(),
        .mappings = &f.mappings,
        .migration_pair = .{ 1, 2 },
        .max_connections = 2,
        .max_handles = 2,
    };
    defer service.deinit();
    const a = try service.connect();
    const b = try service.connect();
    try t.expectError(error.ConnectionLimit, service.connect());
    const writer = try service.open(a, 2, true);
    try service.write(a, writer.handle, "durable", 0);
    service.disconnect(a);
    const recovered = try service.open(b, 2, true);
    try t.expectEqual(@as(u64, 7), recovered.size);
    const reader = try service.open(b, 2, false);
    try t.expectError(error.HandleLimit, service.open(b, 2, false));
    try service.write(b, recovered.handle, "!", 7);
    f.meta.unavailable = true;
    try t.expectError(error.ClusterUnavailable, service.close(b, recovered.handle));
    f.meta.unavailable = false;
    try t.expectError(error.InvalidHandle, service.sync(b, recovered.handle));
    try t.expectError(error.WalSessionFailed, service.size(b, reader.handle));
    try t.expectError(error.WalSessionFailed, service.open(b, 2, true));
    try service.close(b, reader.handle);
    const final = try service.open(b, 2, false);
    var buffer: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 8), try service.read(b, final.handle, &buffer, 0));
    try t.expectEqualStrings("durable!", &buffer);
    service.disconnect(b);
    try t.expectEqual(@as(u32, 0), service.handles.count());
    try t.expectEqual(@as(u32, 0), service.sessions.count());
}

test "file service concurrent owners cannot acquire two writers" {
    var f = try Fixture.init();
    defer f.deinit();
    const Service = @import("file_service.zig").Service;
    var service: Service = .{
        .allocator = t.allocator,
        .io = t.io,
        .metadata = f.meta.api(),
        .mappings = &f.mappings,
        .migration_pair = .{ 1, 2 },
    };
    defer service.deinit();
    const a = try service.connect();
    const b = try service.connect();
    const Race = struct {
        fn run(s: *Service, owner: u64, gate: *std.Io.Event) !Service.Opened {
            gate.waitUncancelable(t.io);
            return s.open(owner, 2, true);
        }
    };
    var gate: std.Io.Event = .unset;
    var first = try t.io.concurrent(Race.run, .{ &service, a, &gate });
    gate.set(t.io);
    const second = service.open(b, 2, true);
    const result = first.await(t.io);
    if (result) |opened| {
        try t.expectError(error.FileBusy, second);
        try service.close(a, opened.handle);
    } else |err| {
        try t.expectEqual(error.FileBusy, err);
        try service.close(b, (try second).handle);
    }
    try t.expectEqual(@as(u32, 0), service.handles.count());
}

test "mutable access migrates immutable contents once and preserves historical objects" {
    var f = try Fixture.init();
    defer f.deinit();
    const version = try f.seed("original");
    var session = try f.open();
    var buffer: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 8), try session.read(&buffer, 0));
    try t.expectEqualStrings("original", &buffer);
    const inode = (try session.data.session.replicas[0].data.stat(t.io)).inode;
    try session.write("X", 2);
    try session.sync();
    try session.write("Y", 3);
    try session.collect();
    try t.expectEqual(inode, (try session.data.session.replicas[0].data.stat(t.io)).inode);
    session.close();
    session = try f.open();
    defer session.close();
    try t.expectEqual(@as(usize, 8), try session.read(&buffer, 0));
    try t.expectEqualStrings("orXYinal", &buffer);
    for (f.mappings) |mapping| {
        const store = try objects.Store.openMapping(t.io, mapping, false);
        defer store.close();
        const old = try store.openVerified(version);
        old.close(t.io);
    }
    try t.expectEqual(@as(usize, 1), f.meta.state.versions.items.len);
}

test "mutable access serializes owners and reconciles acknowledged WAL after reopen" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    try t.expectError(error.FileBusy, f.open());
    try session.write("durable", 0);
    try t.expectEqual(@as(u64, 0), f.meta.state.get(2).?.mutable_file.?.size);
    session.close();
    session = try f.open();
    defer session.close();
    try t.expectEqual(@as(u64, 7), f.meta.state.get(2).?.mutable_file.?.size);
    var buffer: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 7), try session.read(&buffer, 0));
    try t.expectEqualStrings("durable", buffer[0..7]);
}

test "mutable attachment reply loss reopens the bound generation instead of recreating it" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.seed("retained");
    f.meta.lose_reply = true;
    try t.expectError(error.ReplyLost, f.open());
    const bound = f.meta.state.get(2).?.mutable_file.?;
    var session = try f.open();
    defer session.close();
    try t.expectEqual(bound.generation, session.data.session.identity.generation);
    var buffer: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 8), try session.read(&buffer, 0));
    try t.expectEqualStrings("retained", &buffer);
}

test "mutable checkpoint reply loss freezes access and reopen observes committed state" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    try session.write("new", 0);
    f.meta.lose_reply = true;
    try t.expectError(error.ReplyLost, session.sync());
    try t.expectError(error.WalSessionFailed, session.write("bad", 0));
    session.close();
    session = try f.open();
    defer session.close();
    try t.expectEqual(@as(u64, 3), f.meta.state.get(2).?.mutable_file.?.size);
    try session.truncate(1);
    try session.collect();
    try t.expectEqual(@as(u64, 1), f.meta.state.get(2).?.mutable_file.?.size);
}

test "mutable read freezes on replaced directory and refuses stale pinned descriptors" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("old", 0);
    const name = session.name[0..session.name_len];
    try session.parents[0].rename(name, session.parents[0], "moved", t.io);
    try session.parents[0].createDir(t.io, name, .default_dir);
    var bytes: [3]u8 = undefined;
    try t.expectError(error.BackendMountMismatch, session.read(&bytes, 0));
    try t.expectError(error.WalSessionFailed, session.sync());
    try t.expectEqual(@as(u64, 0), f.meta.state.get(2).?.mutable_file.?.size);
}

test "mutable metadata conflict retains data checkpoint for later reconciliation" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    try session.write("kept", 0);
    f.meta.conflict = true;
    try t.expectError(error.MetadataConflict, session.collect());
    session.close();
    f.meta.conflict = false;
    session = try f.open();
    defer session.close();
    try t.expectEqual(@as(u64, 4), f.meta.state.get(2).?.mutable_file.?.size);
    try session.collect();
}

test "failed mutable migration preserves the original binding and healthy objects" {
    var f = try Fixture.init();
    defer f.deinit();
    const version = try f.seed("original");
    f.meta.conflict = true;
    try t.expectError(error.MetadataConflict, f.open());
    try t.expectEqual(version.id, f.meta.state.get(2).?.current_version);
    try t.expect(f.meta.state.get(2).?.mutable_file == null);
    for (f.mappings) |mapping| {
        const store = try objects.Store.openMapping(t.io, mapping, false);
        defer store.close();
        const original = try store.openVerified(version);
        original.close(t.io);
    }
    f.meta.conflict = false;
    var session = try f.open();
    defer session.close();
    var bytes: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 8), try session.read(&bytes, 0));
    try t.expectEqualStrings("original", &bytes);
}

test "mutable access freezes on metadata outage and replacement of the data file" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    try session.write("data", 0);
    f.meta.unavailable = true;
    var bytes: [4]u8 = undefined;
    try t.expectError(error.ClusterUnavailable, session.read(&bytes, 0));
    f.meta.unavailable = false;
    try t.expectError(error.WalSessionFailed, session.write("bad", 0));
    session.close();
    session = try f.open();
    defer session.close();
    try session.dirs[1].rename("data", session.dirs[1], "old-data", t.io);
    const replacement = try session.dirs[1].createFile(t.io, "data", .{ .read = true });
    replacement.close(t.io);
    try t.expectError(error.BackendMountMismatch, session.write("bad", 0));
    try t.expectError(error.WalSessionFailed, session.read(&bytes, 0));
}

test "mutable reads detect either replica corruption and retain WAL evidence" {
    for (0..2) |bad| {
        var f = try Fixture.init();
        defer f.deinit();
        var session = try f.open();
        defer session.close();
        try session.write("original", 0);
        const sequence = session.data.checkpoint.next;
        const log_size = (try session.data.session.replicas[0].log.stat(t.io)).size;
        try session.data.session.replicas[bad].data.writePositionalAll(t.io, "X", 3);
        var bytes: [8]u8 = undefined;
        try t.expectError(error.ReplicaContentMismatch, session.read(&bytes, 0));
        try t.expectError(error.WalSessionFailed, session.collect());
        try t.expectError(error.WalSessionFailed, session.write("bad", 0));
        try t.expectEqual(sequence, session.data.checkpoint.next);
        try t.expectEqual(log_size, (try session.data.session.replicas[0].log.stat(t.io)).size);
        try t.expectEqual(@as(u64, 0), f.meta.state.get(2).?.mutable_file.?.size);
        try t.expectEqual(@as(usize, 8), try session.data.session.replicas[1 - bad].data.readPositionalAll(t.io, &bytes, 0));
        try t.expectEqualStrings("original", &bytes);
    }
}

test "mutable size mismatch freezes even reads outside the damaged range" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("original", 0);
    try session.data.session.replicas[1].data.writePositionalAll(t.io, "extra", 8);
    try t.expectError(error.WalDataSizeMismatch, session.size());
    var bytes: [1]u8 = undefined;
    try t.expectError(error.WalSessionFailed, session.read(&bytes, 0));
}

test "mutable scrub compares chunk boundaries and sparse tails without checkpointing" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    const empty = try session.scrub();
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &expected, .{});
    try t.expectEqualSlices(u8, &expected, &empty.sha256);
    var bytes: [128 * 1024 + 7]u8 = @splat(0);
    bytes[65535] = 42;
    bytes[65536] = 43;
    bytes[bytes.len - 1] = 44;
    try session.write(bytes[65535..65537], 65535);
    try session.write(bytes[bytes.len - 1 ..], bytes.len - 1);
    const result = try session.scrub();
    std.crypto.hash.sha2.Sha256.hash(&bytes, &expected, .{});
    try t.expectEqualSlices(u8, &expected, &result.sha256);
    try t.expectEqual(bytes.len, result.size);
    try t.expectEqual(session.data.session.next, result.next_sequence);
    try t.expectEqual(@as(u64, 1), session.data.checkpoint.next);
    var output: [bytes.len + 20]u8 = undefined;
    try t.expectEqual(bytes.len, try session.read(&output, 0));
    try t.expectEqualSlices(u8, &bytes, output[0..bytes.len]);
    try t.expectEqual(@as(usize, 0), try session.read(&output, bytes.len));
    try session.data.session.replicas[1].data.writePositionalAll(t.io, "X", bytes.len - 1);
    try t.expectError(error.WalDataMismatch, session.scrub());
    try t.expectError(error.WalSessionFailed, session.sync());
}

test "mutable replica agreement is not proof against identical corruption after WAL retirement" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("original", 0);
    try session.sync();
    for (session.data.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "X", 0);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("Xriginal", &expected, .{});
    const result = try session.scrub();
    try t.expectEqualSlices(u8, &expected, &result.sha256);
}

test "mutable partial reads reject identical dirty corruption without checking unrelated ranges" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("baseline", 0);
    try session.sync();
    try session.write("ABCDE", 2);
    try session.write("xy", 4);
    const before = f.meta.state.get(2).?.mutable_file.?;
    var bytes: [4]u8 = undefined;
    try t.expectEqual(@as(usize, 4), try session.read(&bytes, 3));
    try t.expectEqualStrings("BxyE", &bytes);
    for (session.data.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "Q", 5);
    try t.expectEqual(@as(usize, 2), try session.read(bytes[0..2], 1));
    try t.expectEqualStrings("aA", bytes[0..2]);
    try t.expectError(error.WalDataMismatch, session.read(bytes[0..1], 5));
    try t.expectError(error.WalSessionFailed, session.collect());
    try t.expect(std.meta.eql(before, f.meta.state.get(2).?.mutable_file.?));
}

test "mutable dirty read checks holes EOF and identical truncation before returning cached size" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("tail", 8);
    var bytes: [16]u8 = undefined;
    try t.expectEqual(@as(usize, 7), try session.read(&bytes, 5));
    try t.expectEqualSlices(u8, "\x00\x00\x00tail", bytes[0..7]);
    try t.expectEqual(@as(usize, 0), try session.read(&bytes, 12));
    try t.expectEqual(@as(usize, 0), try session.read(&.{}, std.math.maxInt(u64)));
    for (session.data.session.replicas) |replica| try replica.data.setLength(t.io, 0);
    try t.expectError(error.WalDataSizeMismatch, session.size());
}

test "mutable dirty reads reject corrupt WAL even when both data files agree" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("original", 0);
    for (session.data.session.replicas) |replica| try replica.log.writePositionalAll(t.io, "Q", 112);
    var bytes: [8]u8 = undefined;
    try t.expectError(error.CorruptWal, session.read(&bytes, 0));
    try t.expectError(error.WalSessionFailed, session.sync());
}

test "mutable dirty scrub rejects identical corruption using pending evidence" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("original", 0);
    for (session.data.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "X", 0);
    try t.expectError(error.WalDataMismatch, session.scrub());
    try t.expectEqual(@as(u64, 1), session.data.checkpoint.next);
}

test "mutable size checks the WAL-covered tail byte as well as the reported length" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("original", 0);
    for (session.data.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "\x00", 7);
    try t.expectError(error.WalDataMismatch, session.size());
}

test "mutable seal binds metadata checkpoint and detects identical damage during scrub" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    defer session.close();
    try session.write("original", 0);
    try session.seal();
    const baseline = session.data.seal.?;
    const head = f.meta.state.get(2).?.mutable_file.?;
    try t.expectEqual(head.next_sequence, baseline.next);
    try t.expectEqual(head.size, baseline.size);
    for (session.data.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "X", 0);
    try t.expectError(error.SealedContentMismatch, session.scrub());
    try t.expectError(error.WalSessionFailed, session.write("new", 0));
}

test "mutable checkpoint retains WAL evidence and metadata after identical dirty corruption" {
    var f = try Fixture.init();
    defer f.deinit();
    var session = try f.open();
    try session.write("original", 0);
    const before = f.meta.state.get(2).?.mutable_file.?;
    for (session.data.session.replicas) |replica| try replica.data.writePositionalAll(t.io, "X", 0);
    try t.expectError(error.WalDataMismatch, session.collect());
    try t.expect(std.meta.eql(before, f.meta.state.get(2).?.mutable_file.?));
    session.close();
    session = try f.open();
    defer session.close();
    var bytes: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 8), try session.read(&bytes, 0));
    try t.expectEqualStrings("original", &bytes);
    try t.expectEqual(@as(u64, 8), f.meta.state.get(2).?.mutable_file.?.size);
}
