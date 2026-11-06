const std = @import("std");
const t = std.testing;
const Store = @import("durable.zig").Store;
const m = @import("metadata.zig");
const protocol = @import("machine.zig");

const Fixture = struct {
    tmp: t.TmpDir,
    path: [:0]u8,
    fn init() !Fixture {
        var tmp = t.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(path);
        return .{ .tmp = tmp, .path = try t.allocator.dupeSentinel(u8, path, 0) };
    }
    fn deinit(self: *Fixture) void {
        t.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn apply(store: *Store, index: u64, request: m.Request) !m.Result {
    const data = try std.json.Stringify.valueAlloc(t.allocator, request, .{});
    defer t.allocator.free(data);
    var result = try store.applyEntry(.{ .index = index, .term = 1, .data = data });
    defer result.deinit(store.allocator);
    return protocol.decodeResult(result.response.?);
}

const create: m.Request = .{ .request_id = 1, .command = .{ .create = .{ .parent = 1, .name = "photos", .kind = .directory } } };

test "path mutations are atomic, typed and deduplicated across name reuse and restart" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var memory = try m.State.init(t.allocator);
    defer memory.deinit();
    const removal: m.Request = .{ .request_id = 7, .command = .{ .remove_entry = .{ .parent = 2, .name = "MOVED", .kind = .file } } };
    const commands = [_]m.Request{
        create,
        .{ .request_id = 2, .command = .{ .create = .{ .parent = 2, .name = "child", .kind = .file } } },
        .{ .request_id = 3, .command = .{ .remove_entry = .{ .parent = 1, .name = "photos", .kind = .file } } },
        .{ .request_id = 4, .command = .{ .remove_entry = .{ .parent = 1, .name = "photos", .kind = .directory } } },
        .{ .request_id = 5, .command = .{ .rename_entry = .{ .parent = 2, .name = "CHILD", .new_parent = 2, .new_name = "moved" } } },
        .{ .request_id = 6, .command = .{ .remove_entry = .{ .parent = 2, .name = "child", .kind = .file } } },
        removal,
        .{ .request_id = 8, .command = .{ .create = .{ .parent = 2, .name = "moved", .kind = .file } } },
        removal,
        .{ .request_id = 9, .command = .{ .rename_entry = .{ .parent = 1, .name = "photos", .new_parent = 2, .new_name = "cycle" } } },
        .{ .request_id = 10, .command = .{ .remove_entry = .{ .parent = 2, .name = "../moved", .kind = .file } } },
    };
    const statuses = [_]m.Status{ .ok, .ok, .not_file, .not_empty, .ok, .not_found, .ok, .ok, .ok, .cycle, .invalid_name };
    for (commands, statuses, 1..) |command, status, index| {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        const expected = try memory.apply(command);
        try t.expectEqual(status, expected.status);
        try t.expectEqualDeep(expected, try apply(&store, index, command));
        const bytes = try store.snapshot(t.allocator, index, 1);
        defer t.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(protocol.Image, t.allocator, bytes, .{});
        defer parsed.deinit();
        try t.expectEqualDeep(memory.snapshot(), parsed.value.state);
    }
    try t.expectEqual(@as(u64, 4), memory.lookup(2, "moved").?.id);
}

test "checked namespace mutations reject stale entries and retain receipts across restart" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var memory = try m.State.init(t.allocator);
    defer memory.deinit();
    const stale: m.Entry = .{ .inode = 3, .parent = 2, .name = "child" };
    const moved: m.Entry = .{ .inode = 3, .parent = 1, .name = "moved" };
    const reject: m.Request = .{ .request_id = 4, .command = .{ .remove_checked = stale } };
    const remove: m.Request = .{ .request_id = 7, .command = .{ .remove_checked = moved } };
    const commands = [_]m.Request{
        create,
        .{ .request_id = 2, .command = .{ .create = .{ .parent = 2, .name = "child", .kind = .file } } },
        .{ .request_id = 3, .command = .{ .rename_checked = .{ .source = stale, .parent = 1, .name = "moved" } } },
        reject,
        .{ .request_id = 5, .command = .{ .rename_checked = .{ .source = stale, .parent = 1, .name = "wrong" } } },
        .{ .request_id = 6, .command = .{ .create = .{ .parent = 2, .name = "child", .kind = .file } } },
        reject,
        remove,
        .{ .request_id = 8, .command = .{ .create = .{ .parent = 1, .name = "moved", .kind = .file } } },
        remove,
        .{ .request_id = 9, .command = .{ .remove_checked = moved } },
        .{ .request_id = 10, .command = .{ .remove_checked = .{ .inode = 4, .parent = 1, .name = "child" } } },
        .{ .request_id = 11, .command = .{ .remove_checked = .{ .inode = 4, .parent = 2, .name = "CHILD" } } },
    };
    const statuses = [_]m.Status{ .ok, .ok, .ok, .entry_conflict, .entry_conflict, .ok, .entry_conflict, .ok, .ok, .ok, .entry_conflict, .entry_conflict, .entry_conflict };
    for (commands, statuses, 1..) |command, status, index| {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        const expected = try memory.apply(command);
        try t.expectEqual(status, expected.status);
        try t.expectEqualDeep(expected, try apply(&store, index, command));
        const bytes = try store.snapshot(t.allocator, index, 1);
        defer t.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(protocol.Image, t.allocator, bytes, .{});
        defer parsed.deinit();
        try t.expectEqualDeep(memory.snapshot(), parsed.value.state);
    }
    try t.expectEqual(@as(u64, 4), memory.lookup(2, "child").?.id);
    try t.expectEqual(@as(u64, 5), memory.lookup(1, "moved").?.id);
}

test "directory pages use exclusive case-folded cursors and own their data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    for ([_][]const u8{ "Zulu", "alpha", "Bravo" }, 1..) |name, index| {
        _ = try apply(&store, index, .{ .request_id = index, .command = .{ .create = .{ .parent = 1, .name = name, .kind = .file } } });
    }
    const node = (try store.lookupNode(t.allocator, 1, "BRAVO")).?;
    defer t.allocator.free(node.name);
    try t.expectEqualStrings("Bravo", node.name);
    try t.expectEqual(@as(?m.Node, null), try store.lookupNode(t.allocator, 1, "missing"));
    const first = try store.list(t.allocator, .{ .parent = 1, .limit = 2 });
    defer first.deinit(t.allocator);
    try t.expectEqualStrings("alpha", first.entries[0].name);
    try t.expectEqualStrings("Bravo", first.next.?);
    _ = try apply(&store, 4, .{ .request_id = 4, .command = .{ .remove = .{ .id = node.id } } });
    const second = try store.list(t.allocator, .{ .parent = 1, .after = "BRAVO", .limit = 2 });
    defer second.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), second.entries.len);
    try t.expectEqualStrings("Zulu", second.entries[0].name);
    try t.expect(second.next == null);
    try t.expectEqualStrings("Bravo", first.entries[1].name);
    try t.expectError(error.NotDirectory, store.list(t.allocator, .{ .parent = 2 }));
    try t.expectError(error.NotFound, store.lookupNode(t.allocator, 99, "a"));
    try t.expectError(error.InvalidRequest, store.list(t.allocator, .{ .parent = 1, .limit = 0 }));
    try t.expectError(error.InvalidRequest, store.list(t.allocator, .{ .parent = 1, .after = ".." }));
}

test "maximum directory page fits the bounded RPC envelope with escaped names" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    const empty = try store.list(t.allocator, .{ .parent = 1 });
    defer empty.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), empty.entries.len);
    try t.expect(empty.next == null);
    for (0..17) |i| {
        var name: [255]u8 = @splat(1);
        name[0] = @intCast('a' + i);
        const result = try apply(&store, i + 1, .{ .request_id = i + 1, .command = .{ .create = .{ .parent = 1, .name = &name, .kind = .file } } });
        try t.expectEqual(m.Status.ok, result.status);
    }
    const page = try store.list(t.allocator, .{ .parent = 1 });
    defer page.deinit(t.allocator);
    try t.expectEqual(@as(usize, 16), page.entries.len);
    try t.expect(page.next != null);
    const json = try std.json.Stringify.valueAlloc(t.allocator, page, .{});
    defer t.allocator.free(json);
    const encoded = try @import("wire.zig").encode(t.allocator, json);
    defer t.allocator.free(encoded);
    try t.expectEqualStrings(json, try @import("wire.zig").decode(encoded));
}

test "LMDB node binding survives restart and prevents identity reuse and local writes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const cluster: [16]u8 = @splat(1);
    {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        try t.expectError(error.StoreBusy, Store.open(t.allocator, fixture.path, 16 * 1024 * 1024));
        try store.requireStandalone();
        try store.bindIdentity(cluster, 1);
    }
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    try store.bindIdentity(cluster, 1);
    try t.expectError(error.IdentityMismatch, store.bindIdentity(cluster, 2));
    try t.expectError(error.IdentityMismatch, store.bindIdentity(@splat(2), 1));
    try t.expectError(error.ClusterManagedStore, store.requireStandalone());
}

test "existing standalone metadata cannot become a fresh Raft state machine" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    _ = try apply(&store, 1, create);
    try t.expectError(error.UnboundMetadata, store.bindIdentity(@splat(1), 1));
}

test "LMDB matches reference semantics and retains receipts across restart" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var memory = try m.State.init(t.allocator);
    defer memory.deinit();
    const commands = [_]m.Request{
        create,
        .{ .request_id = 2, .command = .{ .create = .{ .parent = 2, .name = "child", .kind = .file } } },
        .{ .request_id = 3, .command = .{ .remove = .{ .id = 2 } } },
        .{ .request_id = 4, .command = .{ .rename = .{ .id = 3, .parent = 1, .name = "CHILD" } } },
        .{ .request_id = 5, .command = .{ .set_replicas = .{ .id = 3, .replicas = .one } } },
        .{ .request_id = 6, .command = .{ .remove = .{ .id = 2 } } },
        create,
    };
    for (commands, 0..) |command, i| {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        try t.expect(store.stateMachine().supportsDurableApplied());
        try t.expectEqualDeep(try memory.apply(command), try apply(&store, i + 1, command));
        try t.expectEqual(i + 1, (try store.applied()).index);
        const bytes = try store.snapshot(t.allocator, i + 1, 1);
        defer t.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(protocol.Image, t.allocator, bytes, .{});
        defer parsed.deinit();
        try t.expectEqualDeep(memory.snapshot(), parsed.value.state);
    }
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    try t.expectEqual(@as(?u64, 3), try store.lookup(1, "child"));
    const node = (try store.get(t.allocator, 3)).?;
    defer t.allocator.free(node.name);
    try t.expectEqualStrings("CHILD", node.name);
    try t.expectError(error.EntryParseError, apply(&store, 7, create));
    var noop = try store.stateMachine().apply(.{ .index = 9, .term = 2 });
    defer noop.deinit(t.allocator);
    try t.expectEqual(@as(u64, 9), (try store.applied()).index);
}

test "LMDB restore replaces namespace and malformed restore is atomic" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    _ = try apply(&store, 1, create);
    const bytes = try store.snapshot(t.allocator, 3, 1);
    defer t.allocator.free(bytes);
    _ = try apply(&store, 2, .{ .request_id = 2, .command = .{ .remove = .{ .id = 2 } } });
    try store.restore(3, 1, bytes);
    try t.expectEqual(@as(?u64, 2), try store.lookup(1, "PHOTOS"));
    try t.expectError(error.CorruptStore, store.restore(4, 1, "invalid"));
    try t.expectError(error.InvalidSnapshot, store.restore(4, 1, bytes));
    try t.expectEqual(@as(u64, 3), (try store.applied()).index);
    try t.expectEqual(@as(u64, 2), (try apply(&store, 4, create)).inode);
}

test "LMDB map exhaustion rolls back namespace receipts and cursor" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 64 * 1024);
    defer store.close();
    var index: u64 = 1;
    while (index < 1000) : (index += 1) {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file-{d}", .{index});
        const before = try store.snapshot(t.allocator, index - 1, if (index == 1) 0 else 1);
        defer t.allocator.free(before);
        _ = apply(&store, index, .{ .request_id = index, .command = .{ .create = .{ .parent = 1, .name = name, .kind = .file } } }) catch |err| {
            try t.expectEqual(error.MapFull, err);
            const after = try store.snapshot(t.allocator, index - 1, if (index == 1) 0 else 1);
            defer t.allocator.free(after);
            try t.expectEqualStrings(before, after);
            try t.expectEqual(@as(?u64, null), try store.lookup(1, name));
            return;
        };
    }
    return error.ExpectedMapFull;
}

test "LMDB allocation failures roll back apply and restore" {
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{});
}

test "LMDB map-full snapshot replacement preserves previous database" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 64 * 1024);
    defer store.close();
    _ = try apply(&store, 1, create);
    const before = try store.snapshot(t.allocator, 1, 1);
    defer t.allocator.free(before);
    var state = try m.State.init(t.allocator);
    defer state.deinit();
    for (0..200) |i| {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "replacement-{d}", .{i});
        _ = try state.apply(.{ .request_id = i + 1, .command = .{ .create = .{ .parent = 1, .name = name, .kind = .file } } });
    }
    const replacement = try std.json.Stringify.valueAlloc(t.allocator, protocol.Image{ .index = 200, .term = 1, .state = state.snapshot() }, .{});
    defer t.allocator.free(replacement);
    try t.expectError(error.MapFull, store.restore(200, 1, replacement));
    const after = try store.snapshot(t.allocator, 1, 1);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
    try t.expectEqual(@as(?u64, 2), try store.lookup(1, "photos"));
    try t.expectEqual(@as(?u64, null), try store.lookup(1, "replacement-0"));
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    const bytes = try store.snapshot(t.allocator, 2, 1);
    defer t.allocator.free(bytes);
    store.allocator = allocator;
    _ = apply(&store, 1, create) catch |err| {
        store.allocator = t.allocator;
        try t.expectEqual(@as(u64, 0), (try store.applied()).index);
        try t.expectEqual(@as(?u64, null), try store.lookup(1, "photos"));
        return err;
    };
    store.restore(2, 1, bytes) catch |err| {
        store.allocator = t.allocator;
        try t.expectEqual(@as(u64, 1), (try store.applied()).index);
        try t.expectEqual(@as(?u64, 2), try store.lookup(1, "photos"));
        return err;
    };
}

fn publishCommand(id: u64, inode: u64, expected: u64, backends: [2]u64) m.Command {
    return .{ .publish = .{ .expected_version = expected, .version = .{ .id = id, .inode = inode, .size = id, .sha256 = @splat(7), .backends = backends } } };
}

test "version publication matches memory across reopen, CAS conflicts, policy changes and deletion" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var memory = try m.State.init(t.allocator);
    defer memory.deinit();
    const cases = [_]struct { command: m.Command, status: m.Status }{
        .{ .command = .{ .register_backend = .{ .id = 1, .failure_domain = 10 } }, .status = .ok },
        .{ .command = .{ .register_backend = .{ .id = 2, .failure_domain = 10 } }, .status = .ok },
        .{ .command = .{ .register_backend = .{ .id = 3, .failure_domain = 30 } }, .status = .ok },
        .{ .command = .{ .create = .{ .parent = 1, .name = "file", .kind = .file } }, .status = .ok },
        .{ .command = publishCommand(100, 2, 0, .{ 1, 2 }), .status = .same_failure_domain },
        .{ .command = publishCommand(100, 2, 0, .{ 1, 0 }), .status = .replica_mismatch },
        .{ .command = publishCommand(100, 2, 0, .{ 1, 99 }), .status = .backend_not_found },
        .{ .command = publishCommand(100, 2, 0, .{ 1, 3 }), .status = .ok },
        .{ .command = publishCommand(101, 2, 0, .{ 1, 3 }), .status = .version_conflict },
        .{ .command = publishCommand(101, 2, 100, .{ 1, 3 }), .status = .ok },
        .{ .command = publishCommand(100, 2, 101, .{ 1, 3 }), .status = .version_conflict },
        .{ .command = .{ .register_backend = .{ .id = 1, .failure_domain = 20 } }, .status = .already_exists },
        .{ .command = .{ .set_replicas = .{ .id = 2, .replicas = .one } }, .status = .ok },
        .{ .command = publishCommand(102, 2, 101, .{ 1, 3 }), .status = .replica_mismatch },
        .{ .command = publishCommand(102, 2, 101, .{ 1, 0 }), .status = .ok },
        .{ .command = .{ .rename = .{ .id = 2, .parent = 1, .name = "renamed" } }, .status = .ok },
        .{ .command = .{ .remove = .{ .id = 2 } }, .status = .ok },
        .{ .command = publishCommand(103, 2, 102, .{ 1, 0 }), .status = .not_found },
        .{ .command = .{ .create = .{ .parent = 1, .name = "new", .kind = .file } }, .status = .ok },
        .{ .command = publishCommand(102, 3, 0, .{ 1, 3 }), .status = .version_conflict },
        .{ .command = publishCommand(103, 1, 0, .{ 1, 3 }), .status = .not_file },
        .{ .command = publishCommand(0, 3, 0, .{ 1, 3 }), .status = .invalid_version },
        .{ .command = publishCommand(103, 3, 0, .{ 1, 1 }), .status = .same_failure_domain },
    };
    for (cases, 1..) |case, index| {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        const request: m.Request = .{ .request_id = index, .command = case.command };
        const result = try apply(&store, index, request);
        try t.expectEqual(case.status, result.status);
        try t.expectEqualDeep(try memory.apply(request), result);
        const bytes = try store.snapshot(t.allocator, index, 1);
        defer t.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(protocol.Image, t.allocator, bytes, .{});
        defer parsed.deinit();
        try t.expectEqualDeep(memory.snapshot(), parsed.value.state);
    }
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    try t.expectEqual(@as(u64, 100), (try store.getVersion(100)).?.size);
    try t.expectEqual(@as(u64, 10), (try store.getBackend(1)).?.failure_domain);
    try t.expectEqual(m.Status.ok, (try apply(&store, cases.len + 1, .{ .request_id = 8, .command = cases[7].command })).status);
    try t.expectEqual(@as(?m.Node, null), try store.get(t.allocator, 2));
    const image = try store.snapshot(t.allocator, cases.len + 1, 1);
    defer t.allocator.free(image);
    var target = try Fixture.init();
    defer target.deinit();
    var replacement = try Store.open(t.allocator, target.path, 16 * 1024 * 1024);
    defer replacement.close();
    try replacement.restore(cases.len + 1, 1, image);
    try t.expectEqualDeep(try store.getVersion(102), try replacement.getVersion(102));
    try t.expectEqualDeep(try store.getBackend(3), try replacement.getBackend(3));
    const restored = try replacement.snapshot(t.allocator, cases.len + 1, 1);
    defer t.allocator.free(restored);
    try t.expectEqualStrings(image, restored);
}

test "publication allocation failures roll back version, inode, receipt and applied index" {
    try t.checkAllAllocationFailures(t.allocator, publicationAllocationScenario, .{});
}

fn publicationAllocationScenario(allocator: std.mem.Allocator) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    _ = try apply(&store, 1, .{ .request_id = 1, .command = .{ .register_backend = .{ .id = 1, .failure_domain = 10 } } });
    _ = try apply(&store, 2, .{ .request_id = 2, .command = .{ .create = .{ .parent = 1, .name = "file", .kind = .file, .replicas = .one } } });
    const before = try store.snapshot(t.allocator, 2, 1);
    defer t.allocator.free(before);
    store.allocator = allocator;
    _ = apply(&store, 3, .{ .request_id = 3, .command = publishCommand(100, 2, 0, .{ 1, 0 }) }) catch |err| {
        store.allocator = t.allocator;
        const after = try store.snapshot(t.allocator, 2, 1);
        defer t.allocator.free(after);
        try t.expectEqualStrings(before, after);
        return err;
    };
    store.allocator = t.allocator;
    try t.expect((try store.getVersion(100)) != null);
    const published = try store.snapshot(t.allocator, 3, 1);
    defer t.allocator.free(published);
    const replacement = try store.snapshot(t.allocator, 4, 1);
    defer t.allocator.free(replacement);
    store.allocator = allocator;
    store.restore(4, 1, replacement) catch |err| {
        store.allocator = t.allocator;
        const after = try store.snapshot(t.allocator, 3, 1);
        defer t.allocator.free(after);
        try t.expectEqualStrings(published, after);
        return err;
    };
    store.allocator = t.allocator;
}

test "schema one databases and snapshots upgrade without changing legacy request digests" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const legacy_request = "{\"version\":1,\"request_id\":1,\"command\":{\"create\":{\"parent\":1,\"name\":\"photos\",\"kind\":\"directory\",\"replicas\":null}}}";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(legacy_request, &digest, .{});
    try t.expectEqualDeep(digest, try m.requestDigest(t.allocator, create));
    {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        _ = try apply(&store, 1, create);
        var txn = try store.env.begin(false);
        defer txn.abort();
        try txn.put(store.meta_db, "state", "{\"schema\":1,\"index\":1,\"term\":1,\"next_id\":3}");
        try txn.put(store.nodes_db, &.{ 0, 0, 0, 0, 0, 0, 0, 2 }, "{\"id\":2,\"parent\":1,\"name\":\"photos\",\"kind\":\"directory\",\"replicas\":\"two\"}");
        try txn.commit();
    }
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    try t.expectEqual(m.Status.ok, (try apply(&store, 2, create)).status);
    {
        var txn = try store.env.begin(true);
        defer txn.abort();
        try t.expect(std.mem.indexOf(u8, (try txn.get(store.meta_db, "state")).?, "\"schema\":3") != null);
        try t.expectEqual(@as(usize, 0), try txn.count(store.backends_db));
    }
    const legacy = "{\"version\":1,\"index\":3,\"term\":1,\"state\":{\"next_id\":2,\"nodes\":[{\"id\":1,\"parent\":0,\"name\":\"\",\"kind\":\"directory\",\"replicas\":\"two\"}],\"receipts\":[]}}";
    try store.restore(3, 1, legacy);
    const root = (try store.get(t.allocator, 1)).?;
    defer t.allocator.free(root.name);
    try t.expectEqual(@as(u64, 0), root.current_version);
}

test "publication map-full leaves previous version and deduplication state intact" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(t.allocator, fixture.path, 128 * 1024);
    defer store.close();
    _ = try apply(&store, 1, .{ .request_id = 1, .command = .{ .register_backend = .{ .id = 1, .failure_domain = 10 } } });
    _ = try apply(&store, 2, .{ .request_id = 2, .command = .{ .create = .{ .parent = 1, .name = "file", .kind = .file, .replicas = .one } } });
    var current: u64 = 0;
    for (3..1000) |index| {
        const before = try store.snapshot(t.allocator, index - 1, 1);
        defer t.allocator.free(before);
        _ = apply(&store, index, .{ .request_id = index, .command = publishCommand(index, 2, current, .{ 1, 0 }) }) catch |err| {
            try t.expectEqual(error.MapFull, err);
            const after = try store.snapshot(t.allocator, index - 1, 1);
            defer t.allocator.free(after);
            try t.expectEqualStrings(before, after);
            return;
        };
        current = index;
    }
    return error.ExpectedMapFull;
}

test "mutable checkpoint CAS agrees with memory and survives restart snapshot and receipt replay" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var restored_fixture = try Fixture.init();
    defer restored_fixture.deinit();
    var memory = try m.State.init(t.allocator);
    defer memory.deinit();
    const attachment: m.Request = .{ .request_id = 5, .command = .{ .mutable_file = .{ .attach = .{
        .inode = 2,
        .expected_version = 100,
        .file = .{ .generation = 7, .next_sequence = 1, .size = 3, .backends = .{ 1, 2 } },
    } } } };
    const checkpoint: m.Request = .{ .request_id = 6, .command = .{ .mutable_file = .{ .checkpoint = .{
        .inode = 2,
        .generation = 7,
        .expected_sequence = 1,
        .next_sequence = 4,
        .size = 11,
    } } } };
    const Case = struct { request: m.Request, status: m.Status };
    const cases = [_]Case{
        .{ .request = .{ .request_id = 1, .command = .{ .create = .{ .parent = 1, .name = "mutable", .kind = .file } } }, .status = .ok },
        .{ .request = .{ .request_id = 2, .command = .{ .register_backend = .{ .id = 1, .failure_domain = 10 } } }, .status = .ok },
        .{ .request = .{ .request_id = 3, .command = .{ .register_backend = .{ .id = 2, .failure_domain = 20 } } }, .status = .ok },
        .{ .request = .{ .request_id = 4, .command = publishCommand(100, 2, 0, .{ 1, 2 }) }, .status = .ok },
        .{ .request = attachment, .status = .ok },
        .{ .request = checkpoint, .status = .ok },
        .{ .request = .{ .request_id = 7, .command = .{ .mutable_file = .{ .checkpoint = .{ .inode = 2, .generation = 7, .expected_sequence = 1, .next_sequence = 5, .size = 20 } } } }, .status = .sequence_conflict },
        .{ .request = .{ .request_id = 8, .command = .{ .mutable_file = .{ .checkpoint = .{ .inode = 2, .generation = 8, .expected_sequence = 4, .next_sequence = 5, .size = 20 } } } }, .status = .storage_conflict },
        .{ .request = .{ .request_id = 9, .command = .{ .mutable_file = .{ .checkpoint = .{ .inode = 2, .generation = 7, .expected_sequence = 4, .next_sequence = 3, .size = 20 } } } }, .status = .sequence_conflict },
        .{ .request = .{ .request_id = 10, .command = .{ .mutable_file = .{ .checkpoint = .{ .inode = 2, .generation = 7, .expected_sequence = 4, .next_sequence = 4, .size = 20 } } } }, .status = .sequence_conflict },
        .{ .request = .{ .request_id = 11, .command = .{ .mutable_file = .{ .checkpoint = .{ .inode = 2, .generation = 7, .expected_sequence = 4, .next_sequence = 7, .size = 2 } } } }, .status = .ok },
        .{ .request = checkpoint, .status = .ok },
        .{ .request = attachment, .status = .ok },
        .{ .request = .{ .request_id = 12, .command = .{ .set_replicas = .{ .id = 2, .replicas = .one } } }, .status = .replica_mismatch },
        .{ .request = .{ .request_id = 13, .command = publishCommand(101, 2, 0, .{ 1, 2 }) }, .status = .storage_conflict },
        .{ .request = .{ .request_id = 14, .command = attachment.command }, .status = .storage_conflict },
        .{ .request = .{ .request_id = 15, .command = .{ .rename = .{ .id = 2, .parent = 1, .name = "renamed" } } }, .status = .ok },
    };
    for (cases, 1..) |case, index| {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        const expected = try memory.apply(case.request);
        try t.expectEqual(case.status, expected.status);
        try t.expectEqualDeep(expected, try apply(&store, index, case.request));
        const bytes = try store.snapshot(t.allocator, index, 1);
        defer t.allocator.free(bytes);
        const image = try std.json.parseFromSlice(protocol.Image, t.allocator, bytes, .{});
        defer image.deinit();
        try t.expectEqual(@as(u32, 3), image.value.version);
        try t.expectEqualDeep(memory.snapshot(), image.value.state);
        var restored = try Store.open(t.allocator, restored_fixture.path, 16 * 1024 * 1024);
        defer restored.close();
        try restored.restore(index, 1, bytes);
        const snapshot = try restored.snapshot(t.allocator, index, 1);
        defer t.allocator.free(snapshot);
        try t.expectEqualStrings(bytes, snapshot);
    }
    try t.expectEqual(@as(u64, 0), memory.get(2).?.current_version);
    try t.expectEqual(@as(u64, 7), memory.get(2).?.mutable_file.?.next_sequence);
    try t.expectEqual(@as(u64, 2), memory.get(2).?.mutable_file.?.size);
    try t.expectEqual(@as(usize, 1), memory.versions.items.len);
}

test "schema two upgrades preserve published objects and legacy publish receipts" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const publication: m.Request = .{ .request_id = 3, .command = publishCommand(100, 2, 0, .{ 1, 0 }) };
    {
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        _ = try apply(&store, 1, .{ .request_id = 1, .command = .{ .register_backend = .{ .id = 1, .failure_domain = 10 } } });
        _ = try apply(&store, 2, .{ .request_id = 2, .command = .{ .create = .{ .parent = 1, .name = "legacy", .kind = .file, .replicas = .one } } });
        _ = try apply(&store, 3, publication);
        var txn = try store.env.begin(false);
        defer txn.abort();
        try txn.put(store.meta_db, "state", "{\"schema\":2,\"index\":3,\"term\":1,\"next_id\":3}");
        try txn.put(store.nodes_db, &.{ 0, 0, 0, 0, 0, 0, 0, 2 }, "{\"id\":2,\"parent\":1,\"name\":\"legacy\",\"kind\":\"file\",\"replicas\":\"one\",\"current_version\":100}");
        try txn.commit();
    }
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    const node = (try store.get(t.allocator, 2)).?;
    defer t.allocator.free(node.name);
    try t.expect(node.mutable_file == null);
    try t.expectEqual(@as(u64, 100), node.current_version);
    try t.expectEqualDeep(publication.command.publish.version, (try store.getVersion(100)).?);
    try t.expectEqual(m.Status.ok, (try apply(&store, 4, publication)).status);
    const bytes = try store.snapshot(t.allocator, 4, 1);
    defer t.allocator.free(bytes);
    const image = try std.json.parseFromSlice(protocol.Image, t.allocator, bytes, .{});
    defer image.deinit();
    var legacy = image.value;
    legacy.version = 2;
    legacy.index = 5;
    const old_snapshot = try std.json.Stringify.valueAlloc(t.allocator, legacy, .{});
    defer t.allocator.free(old_snapshot);
    try store.restore(5, 1, old_snapshot);
    try t.expectEqual(m.Status.ok, (try apply(&store, 6, publication)).status);
}

test "data checkpoint ahead of metadata is reconciled after restart without allocating versions" {
    const files = @import("file_store.zig");
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var backend = t.tmpDir(.{});
    defer backend.cleanup();
    try backend.dir.createDir(t.io, "a", .default_dir);
    try backend.dir.createDir(t.io, "b", .default_dir);
    const a = try backend.dir.openDir(t.io, "a", .{ .iterate = true });
    defer a.close(t.io);
    const b = try backend.dir.openDir(t.io, "b", .{ .iterate = true });
    defer b.close(t.io);
    const identity: @import("file_wal.zig").Identity = .{ .inode = 2, .generation = 7 };
    {
        var data = try files.Store.create(t.allocator, t.io, identity, .{ a, b });
        defer data.close();
        var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
        defer store.close();
        _ = try apply(&store, 1, .{ .request_id = 1, .command = .{ .register_backend = .{ .id = 1, .failure_domain = 10 } } });
        _ = try apply(&store, 2, .{ .request_id = 2, .command = .{ .register_backend = .{ .id = 2, .failure_domain = 20 } } });
        _ = try apply(&store, 3, .{ .request_id = 3, .command = .{ .create = .{ .parent = 1, .name = "mutable", .kind = .file } } });
        try t.expectEqual(m.Status.ok, (try apply(&store, 4, .{ .request_id = 4, .command = .{ .mutable_file = .{ .attach = .{
            .inode = 2,
            .expected_version = 0,
            .file = .{ .generation = 7, .next_sequence = 1, .size = 0, .backends = .{ 1, 2 } },
        } } } })).status);
        try data.write("durable", 0);
        try data.sync();
        // Restart before metadata learns the new checkpoint.
    }
    var data = try files.Store.open(t.allocator, t.io, identity, .{ a, b });
    defer data.close();
    var store = try Store.open(t.allocator, fixture.path, 16 * 1024 * 1024);
    defer store.close();
    const node = (try store.get(t.allocator, 2)).?;
    defer t.allocator.free(node.name);
    try t.expectEqual(@as(u64, 1), node.mutable_file.?.next_sequence);
    try t.expectEqual(@as(u64, 2), data.checkpoint.next);
    const request: m.Request = .{ .request_id = 5, .command = .{ .mutable_file = .{ .checkpoint = .{
        .inode = 2,
        .generation = identity.generation,
        .expected_sequence = node.mutable_file.?.next_sequence,
        .next_sequence = data.checkpoint.next,
        .size = data.checkpoint.size,
    } } } };
    try t.expectEqual(m.Status.ok, (try apply(&store, 5, request)).status);
    try data.collect();
    try t.expectEqual(m.Status.ok, (try apply(&store, 6, request)).status);
    const current = (try store.get(t.allocator, 2)).?;
    defer t.allocator.free(current.name);
    try t.expectEqual(@as(u64, 7), current.mutable_file.?.size);
    try t.expectEqual(@as(u64, 0), current.current_version);
    var txn = try store.env.begin(true);
    defer txn.abort();
    try t.expectEqual(@as(usize, 0), try txn.count(store.versions_db));
}
