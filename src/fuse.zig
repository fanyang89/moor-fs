const std = @import("std");
const nas = @import("nas_fs");
const m = nas.metadata;
const allocator = std.heap.smp_allocator;

const Entry = extern struct { id: u64, parent: u64, directory: c_int, name: [256]u8 };
const Api = extern struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, u64, ?[*:0]const u8, *Entry) callconv(.c) c_int,
    list: *const fn (*anyopaque, u64, *?[*]Entry, *usize) callconv(.c) c_int,
    free: *const fn ([*]Entry, usize) callconv(.c) void,
};
extern fn nas_fuse_run(path: [*:0]const u8, api: *const Api) c_int;

const Client = struct {
    endpoints: []const u8,

    fn query(self: *Client, comptime T: type, method: []const u8, request: anytype) !std.json.Parsed(T) {
        const json = try std.json.Stringify.valueAlloc(allocator, request, .{});
        defer allocator.free(json);
        const response = try nas.runtime.call(allocator, self.endpoints, method, json);
        defer allocator.free(response);
        return std.json.parseFromSlice(T, allocator, response, .{ .allocate = .alloc_always });
    }

    fn getNode(self: *Client, id: u64, name: ?[*:0]const u8) !Entry {
        const result = if (name) |n|
            try self.query(?m.Node, "Lookup", .{ .parent = id, .name = std.mem.span(n) })
        else
            try self.query(?m.Node, "Get", .{ .id = id });
        defer result.deinit();
        return entry(result.value orelse return error.NotFound);
    }

    fn readDirectory(self: *Client, id: u64) ![]Entry {
        const parent = try self.getNode(id, null);
        if (parent.directory == 0) return error.NotDirectory;
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(allocator);
        var dot = parent;
        dot.name = @splat(0);
        dot.name[0] = '.';
        try entries.append(allocator, dot);
        dot.id = if (parent.parent == 0) id else parent.parent;
        dot.name[1] = '.';
        try entries.append(allocator, dot);
        var after: ?[]u8 = null;
        defer if (after) |name| allocator.free(name);
        for (0..m.max_nodes) |_| {
            const page = try self.query(struct { entries: []m.Node, next: ?[]const u8 }, "List", .{ .parent = id, .after = after });
            defer page.deinit();
            for (page.value.entries) |node| {
                if (entries.items.len >= m.max_nodes + 2) return error.DirectoryChanged;
                for (entries.items[2..]) |existing| if (existing.id == node.id) return error.DirectoryChanged;
                try entries.append(allocator, try entry(node));
            }
            if (page.value.next) |next| {
                const copy = try allocator.dupe(u8, next);
                if (after) |name| allocator.free(name);
                after = copy;
            } else return entries.toOwnedSlice(allocator);
        }
        return error.DirectoryChanged;
    }
};

fn entry(node: m.Node) !Entry {
    if (node.name.len > 255) return error.InvalidResponse;
    var result: Entry = .{ .id = node.id, .parent = node.parent, .directory = @intFromBool(node.kind == .directory), .name = @splat(0) };
    @memcpy(result.name[0..node.name.len], node.name);
    return result;
}

fn errno(err: anyerror) c_int {
    return switch (err) {
        error.NotFound => 2,
        error.NotDirectory => 20,
        error.OutOfMemory => 12,
        error.DirectoryChanged => 11,
        else => 5,
    };
}

fn get(context: *anyopaque, id: u64, name: ?[*:0]const u8, out: *Entry) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    out.* = client.getNode(id, name) catch |err| return errno(err);
    return 0;
}

fn list(context: *anyopaque, id: u64, out: *?[*]Entry, count: *usize) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    const entries = client.readDirectory(id) catch |err| return errno(err);
    out.* = entries.ptr;
    count.* = entries.len;
    return 0;
}

fn free(entries: [*]Entry, count: usize) callconv(.c) void {
    allocator.free(entries[0..count]);
}

pub fn mount(gpa: std.mem.Allocator, endpoints: []const u8, path: []const u8) !void {
    var client: Client = .{ .endpoints = endpoints };
    _ = try client.getNode(1, null);
    const mountpoint = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(mountpoint);
    const api: Api = .{ .context = &client, .get = get, .list = list, .free = free };
    if (nas_fuse_run(mountpoint, &api) != 0) return error.FuseFailed;
}
