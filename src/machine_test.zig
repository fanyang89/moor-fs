const std = @import("std");
const raft = @import("raftz");
const m = @import("metadata.zig");
const machine = @import("machine.zig");
const testing = std.testing;

const create_json =
    \\{"request_id":1,"command":{"create":{"parent":1,"name":"photos","kind":"directory"}}}
;

fn apply(target: *machine.Machine, index: u64, data: []const u8) !m.Result {
    var result = try target.stateMachine().apply(.{ .index = index, .term = 1, .data = @constCast(data) });
    defer result.deinit(target.allocator);
    return machine.decodeResult(result.response.?);
}

test "replicated replay produces identical state and business errors do not fail Raft" {
    var a = try machine.Machine.init(testing.allocator);
    defer a.deinit();
    var b = try machine.Machine.init(testing.allocator);
    defer b.deinit();
    const commands = [_][]const u8{
        create_json,
        \\{ "version": 1, "request_id": 1, "command": { "create": { "kind": "directory", "name": "photos", "parent": 1, "replicas": null } } }
        ,
        \\{"request_id":2,"command":{"create":{"parent":1,"name":"PHOTOS","kind":"file"}}}
        ,
        \\{"request_id":3,"command":{"remove":{"id":99}}}
        ,
    };
    for (commands, 0..) |command, i| {
        try testing.expectEqualDeep(try apply(&a, i + 1, command), try apply(&b, i + 1, command));
    }
    var first = try a.stateMachine().takeSnapshot(testing.allocator, a.index, a.term, .{});
    defer first.deinit(testing.allocator);
    var second = try b.stateMachine().takeSnapshot(testing.allocator, b.index, b.term, .{});
    defer second.deinit(testing.allocator);
    try testing.expectEqualStrings(first.data, second.data);
    try testing.expectEqual(@as(u64, 4), a.index);
    try testing.expect(!a.stateMachine().supportsDurableApplied());
}

test "snapshot restores namespace and deduplication and owns its memory" {
    var source = try machine.Machine.init(testing.allocator);
    defer source.deinit();
    const expected = try apply(&source, 1, create_json);
    var destination = try machine.Machine.init(testing.allocator);
    defer destination.deinit();
    {
        var voters = [_]u64{ 1, 2, 3 };
        var snapshot = try source.stateMachine().takeSnapshot(testing.allocator, 2, 1, .{ .voters = &voters });
        defer snapshot.deinit(testing.allocator);
        try testing.expectEqualSlices(u64, &voters, snapshot.metadata.conf_state.voters);
        var reader: BufferReader = .{ .data = snapshot.data };
        try destination.stateMachine().restoreSnapshot(snapshot.metadata, reader.reader());
    }
    try testing.expectEqualStrings("photos", destination.state.get(expected.inode).?.name);
    try testing.expectEqualDeep(expected, try apply(&destination, 3, create_json));
    try testing.expectEqual(@as(usize, 2), destination.state.nodes.items.len);
}

test "malformed commands and corrupt snapshots leave state and cursor unchanged" {
    var target = try machine.Machine.init(testing.allocator);
    defer target.deinit();
    _ = try apply(&target, 1, create_json);
    try testing.expectError(error.EntryParseError, apply(&target, 2, "not JSON"));
    try testing.expectError(error.EntryParseError, apply(&target, 1, create_json));
    const bad =
        \\{"version":1,"index":2,"term":1,"state":{"next_id":3,"nodes":[{"id":1,"parent":0,"name":"","kind":"directory","replicas":"two"},{"id":2,"parent":2,"name":"loop","kind":"directory","replicas":"two"}],"receipts":[]}}
    ;
    var reader: BufferReader = .{ .data = bad };
    try testing.expectError(error.EntryParseError, target.stateMachine().restoreSnapshot(.{ .index = 2, .term = 1 }, reader.reader()));
    try testing.expectEqual(@as(u64, 1), target.index);
    try testing.expectEqualStrings("photos", target.state.get(2).?.name);
    var mismatch: BufferReader = .{ .data = bad };
    try testing.expectError(error.EntryParseError, target.stateMachine().restoreSnapshot(.{ .index = 3, .term = 1 }, mismatch.reader()));
}

test "empty Raft entries advance cursor without creating a receipt" {
    var target = try machine.Machine.init(testing.allocator);
    defer target.deinit();
    var result = try target.stateMachine().apply(.{ .index = 1, .term = 1 });
    defer result.deinit(testing.allocator);
    try testing.expect(result.response == null);
    try testing.expectEqual(@as(u64, 1), target.index);
    try testing.expectEqual(@as(usize, 0), target.state.receipts.items.len);
}

test "state machine allocation failures do not partially apply or restore" {
    try testing.checkAllAllocationFailures(testing.allocator, machineAllocationScenario, .{});
}

fn machineAllocationScenario(allocator: std.mem.Allocator) !void {
    var target = try machine.Machine.init(allocator);
    defer target.deinit();
    _ = apply(&target, 1, create_json) catch |err| {
        try testing.expectEqual(@as(u64, 0), target.index);
        try testing.expectEqual(@as(usize, 1), target.state.nodes.items.len);
        try testing.expectEqual(@as(usize, 0), target.state.receipts.items.len);
        return err;
    };
    var snapshot = try target.stateMachine().takeSnapshot(testing.allocator, 1, 1, .{});
    defer snapshot.deinit(testing.allocator);
    var replacement = try machine.Machine.init(allocator);
    defer replacement.deinit();
    var reader: BufferReader = .{ .data = snapshot.data };
    replacement.stateMachine().restoreSnapshot(snapshot.metadata, reader.reader()) catch |err| {
        try testing.expectEqual(@as(u64, 0), replacement.index);
        try testing.expectEqual(@as(usize, 1), replacement.state.nodes.items.len);
        try testing.expectEqual(@as(usize, 0), replacement.state.receipts.items.len);
        return err;
    };
}

const BufferReader = struct {
    data: []const u8,
    offset: usize = 0,

    fn reader(self: *BufferReader) raft.SnapshotReader {
        return .{ .ctx = self, .vtable = &.{ .read = read } };
    }

    fn read(ctx: *anyopaque, out: []u8) raft.Error!usize {
        const self: *BufferReader = @ptrCast(@alignCast(ctx));
        const count = @min(out.len, self.data.len - self.offset, 7);
        @memcpy(out[0..count], self.data[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};
