const std = @import("std");
const raft = @import("raftz");
const metadata = @import("metadata.zig");

pub const max_command_bytes = 4096;
pub const max_snapshot_bytes = 8 * 1024 * 1024;
pub const response_size = 10;

pub const Image = struct {
    version: u32 = 2,
    index: u64,
    term: u64,
    state: metadata.Snapshot,
};

pub const Machine = struct {
    allocator: std.mem.Allocator,
    state: metadata.State,
    index: u64 = 0,
    term: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Machine {
        return .{ .allocator = allocator, .state = try metadata.State.init(allocator) };
    }

    pub fn deinit(self: *Machine) void {
        self.state.deinit();
        self.* = undefined;
    }

    pub fn stateMachine(self: *Machine) raft.StateMachine {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn apply(ctx: *anyopaque, entry: raft.Entry) raft.Error!raft.ApplyResult {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        if (entry.entry_type != .normal or entry.index <= self.index or entry.term == 0 or entry.term < self.term)
            return error.EntryParseError;
        if (entry.data.len == 0) {
            self.index = entry.index;
            self.term = entry.term;
            return .{};
        }
        if (entry.data.len > max_command_bytes) return error.MessageTooLarge;
        const parsed = std.json.parseFromSlice(metadata.Request, self.allocator, entry.data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EntryParseError,
        };
        defer parsed.deinit();
        const response = try self.allocator.alloc(u8, response_size);
        errdefer self.allocator.free(response);
        const result = try self.state.apply(parsed.value);
        response[0] = 1;
        response[1] = @backingInt(result.status);
        std.mem.writeInt(u64, response[2..10], result.inode, .little);
        self.index = entry.index;
        self.term = entry.term;
        return .{ .response = response };
    }

    fn takeSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator, index: u64, term: u64, conf: raft.ConfState) raft.Error!raft.Snapshot {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        if (index < self.index or term < self.term or (index == 0) != (term == 0)) return error.SnapshotOutOfDate;
        const data = try std.json.Stringify.valueAlloc(allocator, Image{
            .index = index,
            .term = term,
            .state = self.state.snapshot(),
        }, .{});
        errdefer allocator.free(data);
        if (data.len > max_snapshot_bytes) return error.MessageTooLarge;
        return .{
            .data = data,
            .metadata = .{ .index = index, .term = term, .conf_state = try raft.cloneConfState(allocator, conf) },
        };
    }

    fn restoreSnapshot(ctx: *anyopaque, snapshot: raft.SnapshotMetadata, reader: raft.SnapshotReader) raft.Error!void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        if (snapshot.index < self.index or snapshot.term < self.term) return error.SnapshotOutOfDate;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = try reader.read(&buffer);
            if (count == 0) break;
            if (count > buffer.len or count > max_snapshot_bytes - bytes.items.len) return error.MessageTooLarge;
            try bytes.appendSlice(self.allocator, buffer[0..count]);
        }
        const parsed = std.json.parseFromSlice(Image, self.allocator, bytes.items, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EntryParseError,
        };
        defer parsed.deinit();
        const image = parsed.value;
        if ((image.version != 1 and image.version != 2) or image.index != snapshot.index or image.term != snapshot.term or
            (image.index == 0) != (image.term == 0)) return error.EntryParseError;
        const replacement = metadata.State.restore(self.allocator, image.state) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EntryParseError,
        };
        self.state.deinit();
        self.state = replacement;
        self.index = snapshot.index;
        self.term = snapshot.term;
    }

    const vtable: raft.StateMachine.VTable = .{
        .apply = apply,
        .take_snapshot = takeSnapshot,
        .restore_snapshot = restoreSnapshot,
    };
};

pub fn decodeResult(bytes: []const u8) !metadata.Result {
    if (bytes.len != response_size or bytes[0] != 1) return error.InvalidResponse;
    const status = std.enums.fromInt(metadata.Status, bytes[1]) orelse return error.InvalidResponse;
    return .{ .status = status, .inode = std.mem.readInt(u64, bytes[2..10], .little) };
}
