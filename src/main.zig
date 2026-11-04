const std = @import("std");
const nas = @import("nas_fs");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    if (args.len >= 3 and (std.mem.eql(u8, args[1], "metadata-show") or std.mem.eql(u8, args[1], "metadata-apply"))) {
        const show = std.mem.eql(u8, args[1], "metadata-show");
        if (args.len != (if (show) @as(usize, 3) else 6)) return error.InvalidArguments;
        const path = try allocator.dupeSentinel(u8, args[2], 0);
        var store = try nas.Store.open(allocator, path, 256 * 1024 * 1024);
        defer store.close();
        if (show) {
            const cursor = try store.applied();
            const data = try store.snapshot(allocator, cursor.index, cursor.term);
            try writer.print("{s}\n", .{data});
        } else {
            var result = try store.applyEntry(.{
                .index = try std.fmt.parseInt(u64, args[3], 10),
                .term = try std.fmt.parseInt(u64, args[4], 10),
                .data = @constCast(args[5]),
            });
            defer result.deinit(allocator);
            if (result.response) |response| {
                const decoded = try nas.machine.decodeResult(response);
                try writer.print("status={s} inode={d}\n", .{ @tagName(decoded.status), decoded.inode });
            }
        }
        try writer.flush();
        return;
    }
    if (args.len != 2 or !std.mem.eql(u8, args[1], "metadata-demo")) {
        try writer.writeAll("Usage:\n  nas-fs metadata-demo\n  nas-fs metadata-show DIRECTORY\n  nas-fs metadata-apply DIRECTORY INDEX TERM JSON\nLocal metadata tools; DIRECTORY must exist. No SMB or Raft networking.\n");
        try writer.flush();
        return;
    }
    var machine = try nas.Machine.init(allocator);
    defer machine.deinit();
    const commands = [_]nas.metadata.Request{
        .{ .request_id = 1, .command = .{ .create = .{ .parent = 1, .name = "photos", .kind = .directory } } },
        .{ .request_id = 2, .command = .{ .create = .{ .parent = 2, .name = "image.jpg", .kind = .file } } },
        .{ .request_id = 3, .command = .{ .rename = .{ .id = 3, .parent = 1, .name = "cover.jpg" } } },
        .{ .request_id = 4, .command = .{ .set_replicas = .{ .id = 3, .replicas = .one } } },
    };
    for (commands, 0..) |request, i| {
        const data = try std.json.Stringify.valueAlloc(allocator, request, .{});
        defer allocator.free(data);
        var applied = try machine.stateMachine().apply(.{ .index = i + 1, .term = 1, .data = data });
        defer applied.deinit(allocator);
        const result = try nas.machine.decodeResult(applied.response.?);
        try writer.print("request={d} status={s} inode={d}\n", .{ request.request_id, @tagName(result.status), result.inode });
    }
    var snapshot = try machine.stateMachine().takeSnapshot(allocator, machine.index, machine.term, .{});
    defer snapshot.deinit(allocator);
    try writer.print("snapshot={s}\n", .{snapshot.data});
    try writer.flush();
}
