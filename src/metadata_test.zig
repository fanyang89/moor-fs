const std = @import("std");
const m = @import("metadata.zig");
const testing = std.testing;

test "version hashes have a stable numeric JSON representation for arbitrary bytes" {
    for ([_]u8{ 0, 7, 65, 128, 255 }) |byte| {
        const version: m.Version = .{ .id = 1, .inode = 2, .size = 0, .sha256 = @splat(byte), .backends = .{ 1, 0 } };
        const json = try std.json.Stringify.valueAlloc(testing.allocator, version, .{});
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"sha256\":[") != null);
        const parsed = try std.json.parseFromSlice(m.Version, testing.allocator, json, .{});
        defer parsed.deinit();
        try testing.expectEqualDeep(version, parsed.value);
    }
}

test "snapshots reject dangling versions and impossible replica references" {
    var state = try m.State.init(testing.allocator);
    defer state.deinit();
    _ = try create(&state, 1, 1, "file", .file);
    _ = try state.apply(.{ .request_id = 2, .command = .{ .register_backend = .{ .id = 1, .failure_domain = 10 } } });
    _ = try state.apply(.{ .request_id = 3, .command = .{ .register_backend = .{ .id = 2, .failure_domain = 20 } } });
    _ = try state.apply(.{ .request_id = 4, .command = .{ .publish = .{ .expected_version = 0, .version = .{ .id = 100, .inode = 2, .size = 3, .sha256 = @splat(1), .backends = .{ 1, 2 } } } } });
    try m.validateSnapshot(state.snapshot());
    state.nodes.items[1].current_version = 999;
    try testing.expectError(error.InvalidSnapshot, m.validateSnapshot(state.snapshot()));
    state.nodes.items[1].current_version = 100;
    state.backends.items[1].failure_domain = 10;
    try testing.expectError(error.InvalidSnapshot, m.validateSnapshot(state.snapshot()));
    state.backends.items[1].failure_domain = 20;
    state.versions.items[0].backends[1] = 99;
    try testing.expectError(error.InvalidSnapshot, m.validateSnapshot(state.snapshot()));
    state.versions.items[0].backends[1] = 2;
    state.versions.items[0].size = std.math.maxInt(u64);
    try testing.expectError(error.InvalidSnapshot, m.validateSnapshot(state.snapshot()));
    state.versions.items[0].size = 3;
    state.nodes.items[1].kind = .directory;
    try testing.expectError(error.InvalidSnapshot, m.validateSnapshot(state.snapshot()));
    state.nodes.items[1].kind = .file;
    try m.validateSnapshot(state.snapshot());
    var restored = try m.State.restore(testing.allocator, state.snapshot());
    defer restored.deinit();
    try testing.expectEqualDeep(state.snapshot(), restored.snapshot());
}

fn create(state: *m.State, request_id: u64, parent: u64, name: []const u8, kind: m.Kind) !u64 {
    const result = try state.apply(.{ .request_id = request_id, .command = .{
        .create = .{ .parent = parent, .name = name, .kind = kind },
    } });
    try testing.expectEqual(m.Status.ok, result.status);
    return result.inode;
}

test "default replicas, inherited policy, and moves preserve file policy" {
    var state = try m.State.init(testing.allocator);
    defer state.deinit();
    const photos = try create(&state, 1, 1, "photos", .directory);
    const file = try create(&state, 2, photos, "a.jpg", .file);
    try testing.expectEqual(m.Replicas.two, state.get(file).?.replicas);
    _ = try state.apply(.{ .request_id = 3, .command = .{ .set_replicas = .{ .id = photos, .replicas = .one } } });
    const next = try create(&state, 4, photos, "b.jpg", .file);
    try testing.expectEqual(m.Replicas.one, state.get(next).?.replicas);
    try testing.expectEqual(m.Replicas.two, state.get(file).?.replicas);
    const moved = try state.apply(.{ .request_id = 5, .command = .{ .rename = .{ .id = next, .parent = 1, .name = "B.JPG" } } });
    try testing.expectEqual(m.Status.ok, moved.status);
    try testing.expectEqual(next, state.lookup(1, "b.jpg").?.id);
    try testing.expectEqual(m.Replicas.one, state.get(next).?.replicas);
}

test "rename rejects conflicts and cycles without changing namespace" {
    var state = try m.State.init(testing.allocator);
    defer state.deinit();
    const a = try create(&state, 1, 1, "a", .directory);
    const b = try create(&state, 2, a, "b", .directory);
    const c = try create(&state, 3, 1, "c", .file);
    const conflict = try state.apply(.{ .request_id = 4, .command = .{ .rename = .{ .id = a, .parent = 1, .name = "C" } } });
    try testing.expectEqual(m.Status.already_exists, conflict.status);
    const cycle = try state.apply(.{ .request_id = 5, .command = .{ .rename = .{ .id = a, .parent = b, .name = "a" } } });
    try testing.expectEqual(m.Status.cycle, cycle.status);
    try testing.expectEqual(a, state.lookup(1, "a").?.id);
    try testing.expectEqual(c, state.lookup(1, "c").?.id);
    try testing.expectEqual(a, state.get(b).?.parent);
    const nonempty = try state.apply(.{ .request_id = 6, .command = .{ .remove = .{ .id = a } } });
    try testing.expectEqual(m.Status.not_empty, nonempty.status);
    _ = try state.apply(.{ .request_id = 7, .command = .{ .remove = .{ .id = b } } });
    _ = try state.apply(.{ .request_id = 8, .command = .{ .remove = .{ .id = a } } });
    try testing.expect(state.get(a) == null);
    const fresh = try create(&state, 9, 1, "a", .directory);
    try testing.expect(fresh > c);
}

test "retries retain success and failure results and reject request ID reuse" {
    var state = try m.State.init(testing.allocator);
    defer state.deinit();
    const request: m.Request = .{ .request_id = 1, .command = .{ .create = .{ .parent = 1, .name = "x", .kind = .file } } };
    const first = try state.apply(request);
    const retry = try state.apply(request);
    try testing.expectEqualDeep(first, retry);
    try testing.expectEqual(@as(usize, 2), state.nodes.items.len);
    var reused = request;
    reused.command.create.name = "y";
    try testing.expectEqual(m.Status.request_conflict, (try state.apply(reused)).status);
    var conflict = request;
    conflict.request_id = 2;
    try testing.expectEqual(m.Status.already_exists, (try state.apply(conflict)).status);
    _ = try state.apply(.{ .request_id = 3, .command = .{ .remove = .{ .id = first.inode } } });
    try testing.expectEqual(m.Status.already_exists, (try state.apply(conflict)).status);
    try testing.expectEqualDeep(first, try state.apply(request));
    try testing.expect(state.lookup(1, "x") == null);
}

test "reject invalid names, missing parents, file parents, and root mutations" {
    var state = try m.State.init(testing.allocator);
    defer state.deinit();
    const file = try create(&state, 1, 1, "file", .file);
    const bad = [_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b", "\xff" };
    for (bad, 0..) |name, i| {
        const result = try state.apply(.{ .request_id = i + 2, .command = .{ .create = .{ .parent = 1, .name = name, .kind = .file } } });
        try testing.expectEqual(m.Status.invalid_name, result.status);
    }
    try testing.expectEqual(m.Status.not_directory, (try state.apply(.{ .request_id = 20, .command = .{ .create = .{ .parent = file, .name = "child", .kind = .file } } })).status);
    try testing.expectEqual(m.Status.not_found, (try state.apply(.{ .request_id = 21, .command = .{ .create = .{ .parent = 99, .name = "child", .kind = .file } } })).status);
    try testing.expectEqual(m.Status.root_protected, (try state.apply(.{ .request_id = 22, .command = .{ .remove = .{ .id = 1 } } })).status);
}

test "allocation failures leave create and rename logically unchanged" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var state = try m.State.init(allocator);
    defer state.deinit();
    const commands = [_]m.Request{
        .{ .request_id = 1, .command = .{ .create = .{ .parent = 1, .name = "file", .kind = .file } } },
        .{ .request_id = 2, .command = .{ .rename = .{ .id = 2, .parent = 1, .name = "renamed" } } },
    };
    for (commands) |command| {
        const before = try std.json.Stringify.valueAlloc(testing.allocator, state.snapshot(), .{});
        defer testing.allocator.free(before);
        _ = state.apply(command) catch |err| {
            const after = try std.json.Stringify.valueAlloc(testing.allocator, state.snapshot(), .{});
            defer testing.allocator.free(after);
            try testing.expectEqualStrings(before, after);
            return err;
        };
    }
}
