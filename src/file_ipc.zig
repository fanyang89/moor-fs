//! Versioned local IPC: little-endian u32 length followed by UTF-8 JSON.
//! One outstanding request per connection; binary bytes use hexadecimal.
const std = @import("std");
const Service = @import("file_service.zig").Service;
const Io = std.Io;
const ns = @import("namespace.zig");
const m = @import("metadata.zig");
pub const max_data = 64 * 1024;
pub const max_frame = max_data * 2 + 1024;

const Request = struct {
    version: u32,
    request: u64,
    operation: union(enum) {
        open: struct { inode: u64, writable: bool },
        open_guarded: ns.OpenGuarded,
        read: struct { handle: u64, offset: u64, length: u32 },
        write: struct { handle: u64, offset: u64, hex: []const u8 },
        truncate: struct { handle: u64, length: u64 },
        size: struct { handle: u64 },
        sync: struct { handle: u64 },
        close: struct { handle: u64 },
        stat: struct { inode: u64 },
        lookup: ns.Lookup,
        list: ns.List,
        change: struct { request_id: u64, mutation: ns.Change },
    },
};
const Result = struct {
    handle: ?u64 = null,
    size: ?u64 = null,
    count: ?usize = null,
    hex: ?[]const u8 = null,
    attributes: ?ns.Attributes = null,
    page: ?ns.Page = null,
    change: ?m.Result = null,
};

fn dispatch(service: *Service, owner: u64, request: Request, arena: std.mem.Allocator) !Result {
    if (request.version != 1) return error.UnsupportedVersion;
    switch (request.operation) {
        .open => |op| {
            const opened = try service.open(owner, op.inode, op.writable);
            return .{ .handle = opened.handle, .size = opened.size };
        },
        .open_guarded => |op| {
            const opened = try service.openGuarded(owner, arena, op);
            return .{ .handle = opened.handle, .size = opened.size };
        },
        .read => |op| {
            if (op.length > max_data or op.offset > std.math.maxInt(u64) - @as(u64, op.length)) return error.InvalidRange;
            const bytes = try arena.alloc(u8, op.length);
            const count = try service.read(owner, op.handle, bytes, op.offset);
            const hex = try arena.alloc(u8, count * 2);
            const digits = "0123456789abcdef";
            for (bytes[0..count], 0..) |byte, i| {
                hex[2 * i] = digits[byte >> 4];
                hex[2 * i + 1] = digits[byte & 15];
            }
            return .{ .count = count, .hex = hex };
        },
        .write => |op| {
            if (op.hex.len > max_data * 2 or op.hex.len % 2 != 0 or op.offset > std.math.maxInt(u64) - op.hex.len / 2) return error.InvalidRange;
            const bytes = try arena.alloc(u8, op.hex.len / 2);
            _ = try std.fmt.hexToBytes(bytes, op.hex);
            try service.write(owner, op.handle, bytes, op.offset);
            return .{ .count = bytes.len };
        },
        .truncate => |op| try service.truncate(owner, op.handle, op.length),
        .size => |op| return .{ .size = try service.size(owner, op.handle) },
        .sync => |op| try service.sync(owner, op.handle),
        .close => |op| try service.close(owner, op.handle),
        .stat => |op| return .{ .attributes = try service.stat(owner, arena, op.inode) },
        .lookup => |op| return .{ .attributes = try service.lookup(owner, arena, op) },
        .list => |op| return .{ .page = try service.list(owner, arena, op) },
        .change => |op| return .{ .change = try service.change(owner, op.request_id, op.mutation) },
    }
    return .{};
}

fn exchange(service: *Service, stream: Io.net.Stream, owner: u64) !void {
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(service.io, &read_buffer);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(service.io, &write_buffer);
    while (true) {
        var header: [4]u8 = undefined;
        try reader.interface.readSliceAll(&header);
        const length = std.mem.readInt(u32, &header, .little);
        if (length == 0 or length > max_frame) return error.InvalidFrame;
        var arena = std.heap.ArenaAllocator.init(service.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const frame = try allocator.alloc(u8, length);
        try reader.interface.readSliceAll(frame);
        const request = try std.json.parseFromSliceLeaky(Request, allocator, frame, .{ .allocate = .alloc_always });
        var failure: ?[]const u8 = null;
        const result = dispatch(service, owner, request, allocator) catch |err| blk: {
            if (err == error.Canceled) return error.Canceled;
            failure = @errorName(err);
            break :blk Result{};
        };
        const response = try std.json.Stringify.valueAlloc(allocator, .{
            .version = @as(u32, 1),
            .request = request.request,
            .err = failure,
            .result = result,
        }, .{});
        if (response.len > max_frame) return error.InvalidFrame;
        std.mem.writeInt(u32, &header, @intCast(response.len), .little);
        try writer.interface.writeAll(&header);
        try writer.interface.writeAll(response);
        try writer.interface.flush();
    }
}

fn client(service: *Service, stream: Io.net.Stream, owner: u64) Io.Cancelable!void {
    defer stream.close(service.io);
    defer service.disconnect(owner);
    exchange(service, stream, owner) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        // EOF, incomplete/malformed frames and failed replies all disconnect.
    };
}

/// Requires a fresh absolute runtime directory under a trusted parent. Creating
/// it exclusively with mode 0700 protects the socket before listen; no stale
/// pathname is ever unlinked on startup. SIGKILL leaves it for operator cleanup.
pub fn serve(service: *Service, directory: []const u8) !void {
    if (!std.fs.path.isAbsolute(directory)) return error.AbsolutePathRequired;
    const path = try std.fmt.allocPrint(service.allocator, "{s}/core.sock", .{directory});
    defer service.allocator.free(path);
    const address = try Io.net.UnixAddress.init(path);
    try Io.Dir.cwd().createDir(service.io, directory, .fromMode(0o700));
    defer Io.Dir.cwd().deleteDir(service.io, directory) catch {};
    var server = try address.listen(service.io, .{ .kernel_backlog = 128 });
    defer Io.Dir.cwd().deleteFile(service.io, path) catch {};
    defer server.socket.close(service.io);
    var workers: Io.Group = .init;
    defer workers.cancel(service.io);
    while (true) {
        const stream = try server.accept(service.io);
        const owner = service.connect() catch |err| {
            stream.close(service.io);
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
        workers.concurrent(service.io, client, .{ service, stream, owner }) catch |err| {
            stream.close(service.io);
            service.disconnect(owner);
            return err;
        };
    }
}
