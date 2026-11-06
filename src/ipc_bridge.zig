//! Synchronous C ABI. A transport failure poisons the connection; never replay
//! an uncertain request or silently reconnect with old handles.
const std = @import("std");
const ns = @import("namespace.zig");
const m = @import("metadata.zig");
const c = @import("ipc_sys");
const allocator = std.heap.c_allocator;
const max_frame = 132096;
const Attr = extern struct { inode: u64, parent: u64, size: u64, directory: c_int, name: [256]u8 };
const Page = extern struct { entries: [16]Attr, count: usize, next: [256]u8 };
const Client = struct {
    fd: c_int,
    sequence: u64 = 0,

    fn poison(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn transfer(self: *Client, bytes: []u8, send: bool) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = if (send) c.send(self.fd, bytes.ptr + offset, bytes.len - offset, c.MSG_NOSIGNAL) else c.recv(self.fd, bytes.ptr + offset, bytes.len - offset, 0);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n <= 0) return error.Transport;
            offset += @intCast(n);
        }
    }

    fn call(self: *Client, arena: std.mem.Allocator, operation: anytype) !Reply {
        if (self.fd < 0) return error.Transport;
        errdefer self.poison();
        self.sequence = std.math.add(u64, self.sequence, 1) catch return error.Protocol;
        const request = try std.json.Stringify.valueAlloc(arena, .{ .version = @as(u32, 1), .request = self.sequence, .operation = operation }, .{});
        if (request.len > max_frame) return error.Protocol;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(request.len), .little);
        try self.transfer(&header, true);
        try self.transfer(request, true);
        try self.transfer(&header, false);
        const length = std.mem.readInt(u32, &header, .little);
        if (length == 0 or length > max_frame) return error.Protocol;
        const bytes = try arena.alloc(u8, length);
        try self.transfer(bytes, false);
        const reply = try std.json.parseFromSliceLeaky(Reply, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        if (reply.version != 1 or reply.request != self.sequence) return error.Protocol;
        return reply;
    }
};
const Reply = struct {
    version: u32,
    request: u64,
    err: ?[]const u8,
    result: struct {
        handle: ?u64 = null,
        count: ?usize = null,
        hex: ?[]const u8 = null,
        attributes: ?ns.Attributes = null,
        page: ?ns.Page = null,
        change: ?m.Result = null,
    },
};

fn failure(err: anyerror) c_int {
    return if (err == error.OutOfMemory) c.ENOMEM else c.EIO;
}

fn protocol(client: *Client) c_int {
    client.poison();
    return c.EIO;
}

fn status(reply: Reply) c_int {
    const name = reply.err orelse return 0;
    const errors = .{ .{ "NotFound", c.ENOENT }, .{ "FileBusy", c.EBUSY }, .{ "InvalidHandle", c.EBADF }, .{ "ReadOnlyHandle", c.EACCES }, .{ "NotFile", c.EISDIR }, .{ "InvalidName", c.EINVAL }, .{ "InvalidRange", c.EINVAL } };
    inline for (errors) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return c.EIO;
}

fn attr(value: ns.Attributes, out: *Attr) c_int {
    if (value.node.name.len > 255 or value.size > std.math.maxInt(i64)) return c.EOVERFLOW;
    out.* = .{ .inode = value.node.id, .parent = value.node.parent, .size = value.size, .directory = @intFromBool(value.node.kind == .directory), .name = @splat(0) };
    @memcpy(out.name[0..value.node.name.len], value.node.name);
    return 0;
}

export fn nas_ipc_connect(path: [*:0]const u8, out: *?*Client) c_int {
    out.* = null;
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    const name = std.mem.span(path);
    if (name.len == 0 or name.len >= address.sun_path.len) return c.ENAMETOOLONG;
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..name.len], name);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return c.__errno_location().*;
    if (c.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
        const err = c.__errno_location().*;
        _ = c.close(fd);
        return err;
    }
    const client = allocator.create(Client) catch {
        _ = c.close(fd);
        return c.ENOMEM;
    };
    client.* = .{ .fd = fd };
    out.* = client;
    return 0;
}

export fn nas_ipc_disconnect(client: *Client) void {
    client.poison();
    allocator.destroy(client);
}

fn queryAttr(client: *Client, operation: anytype, out: *Attr) c_int {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = client.call(arena.allocator(), operation) catch |err| return failure(err);
    if (status(reply) != 0) return status(reply);
    return attr(reply.result.attributes orelse return protocol(client), out);
}

export fn nas_ipc_stat(client: *Client, inode: u64, out: *Attr) c_int {
    return queryAttr(client, .{ .stat = .{ .inode = inode } }, out);
}

export fn nas_ipc_lookup(client: *Client, parent: u64, name: [*:0]const u8, out: *Attr) c_int {
    return queryAttr(client, .{ .lookup = .{ .parent = parent, .name = std.mem.span(name) } }, out);
}

export fn nas_ipc_list(client: *Client, parent: u64, after: [*:0]const u8, out: *Page) c_int {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cursor = std.mem.span(after);
    const reply = client.call(arena.allocator(), .{ .list = .{ .parent = parent, .after = if (cursor.len == 0) @as(?[]const u8, null) else cursor } }) catch |err| return failure(err);
    if (status(reply) != 0) return status(reply);
    const page = reply.result.page orelse return protocol(client);
    if (page.entries.len > 16 or (page.entries.len == 0 and page.next != null)) return protocol(client);
    out.* = std.mem.zeroes(Page);
    for (page.entries, 0..) |node, i| {
        const err = attr(.{ .node = node, .size = 0 }, &out.entries[i]);
        if (err != 0) return err;
    }
    out.count = page.entries.len;
    if (page.next) |next| {
        if (next.len == 0 or next.len > 255 or std.mem.eql(u8, next, cursor)) return protocol(client);
        @memcpy(out.next[0..next.len], next);
    }
    return 0;
}

fn open(client: *Client, inode: u64, writable: bool, out: *u64) c_int {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = client.call(arena.allocator(), .{ .open = .{ .inode = inode, .writable = writable } }) catch |err| return failure(err);
    if (status(reply) != 0) return status(reply);
    out.* = reply.result.handle orelse return protocol(client);
    if (out.* == 0) return protocol(client);
    return 0;
}

export fn nas_ipc_open(client: *Client, inode: u64, out: *u64) c_int {
    return open(client, inode, false, out);
}

export fn nas_ipc_open_write(client: *Client, inode: u64, out: *u64) c_int {
    return open(client, inode, true, out);
}

export fn nas_ipc_create_file(client: *Client, parent: u64, name: [*:0]const u8, request_id: u64, out: *u64) c_int {
    return change(client, .{ .create = .{ .parent = parent, .name = std.mem.span(name), .kind = .file } }, request_id, out);
}

export fn nas_ipc_mkdir(client: *Client, parent: u64, name: [*:0]const u8, request_id: u64, out: *u64) c_int {
    return change(client, .{ .create = .{ .parent = parent, .name = std.mem.span(name), .kind = .directory } }, request_id, out);
}

export fn nas_ipc_rename(client: *Client, inode: u64, parent: u64, name: [*:0]const u8, request_id: u64) c_int {
    return change(client, .{ .rename = .{ .inode = inode, .parent = parent, .name = std.mem.span(name) } }, request_id, null);
}

export fn nas_ipc_remove(client: *Client, inode: u64, request_id: u64) c_int {
    return change(client, .{ .remove = .{ .inode = inode } }, request_id, null);
}

export fn nas_ipc_rename_checked(client: *Client, source: *const Attr, parent: u64, name: [*:0]const u8, request_id: u64) c_int {
    return change(client, .{ .rename_checked = .{ .source = .{ .inode = source.inode, .parent = source.parent, .name = std.mem.sliceTo(&source.name, 0) }, .parent = parent, .name = std.mem.span(name) } }, request_id, null);
}

export fn nas_ipc_remove_checked(client: *Client, source: *const Attr, request_id: u64) c_int {
    return change(client, .{ .remove_checked = .{ .inode = source.inode, .parent = source.parent, .name = std.mem.sliceTo(&source.name, 0) } }, request_id, null);
}

fn change(client: *Client, mutation: ns.Change, request_id: u64, out: ?*u64) c_int {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = client.call(arena.allocator(), .{ .change = .{ .request_id = request_id, .mutation = mutation } }) catch |err| return failure(err);
    if (status(reply) != 0) return status(reply);
    const result = reply.result.change orelse return protocol(client);
    switch (result.status) {
        .ok => {
            if (out) |value| {
                if (result.inode == 0) return protocol(client);
                value.* = result.inode;
            }
            return 0;
        },
        .already_exists => return c.EEXIST,
        .not_found => return c.ENOENT,
        .not_directory => return c.ENOTDIR,
        .not_empty => return c.ENOTEMPTY,
        .root_protected => return c.EPERM,
        .cycle => return c.EINVAL,
        .entry_conflict => return c.ESTALE,
        .invalid_name, .invalid_request => return c.EINVAL,
        .capacity_exceeded => return c.ENOSPC,
        else => return c.EIO,
    }
}

fn simple(client: *Client, operation: anytype) c_int {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = client.call(arena.allocator(), operation) catch |err| return failure(err);
    return status(reply);
}

export fn nas_ipc_sync(client: *Client, handle: u64) c_int {
    return simple(client, .{ .sync = .{ .handle = handle } });
}

export fn nas_ipc_truncate(client: *Client, handle: u64, length: u64) c_int {
    return simple(client, .{ .truncate = .{ .handle = handle, .length = length } });
}

export fn nas_ipc_write(client: *Client, handle: u64, offset: u64, data: [*]const u8, length: usize) c_int {
    if (length > 65536) return c.EINVAL;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const hex = arena.allocator().alloc(u8, length * 2) catch return c.ENOMEM;
    const digits = "0123456789abcdef";
    for (data[0..length], 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 15];
    }
    const reply = client.call(arena.allocator(), .{ .write = .{ .handle = handle, .offset = offset, .hex = hex } }) catch |err| return failure(err);
    if (status(reply) != 0) return status(reply);
    if ((reply.result.count orelse return protocol(client)) != length) return protocol(client);
    return 0;
}

export fn nas_ipc_close(client: *Client, handle: u64) c_int {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = client.call(arena.allocator(), .{ .close = .{ .handle = handle } }) catch |err| return failure(err);
    return status(reply);
}

export fn nas_ipc_read(client: *Client, handle: u64, offset: u64, data: [*]u8, length: usize, count: *usize) c_int {
    count.* = 0;
    if (length > 65536) return c.EINVAL;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = client.call(arena.allocator(), .{ .read = .{ .handle = handle, .offset = offset, .length = length } }) catch |err| return failure(err);
    if (status(reply) != 0) return status(reply);
    const n = reply.result.count orelse return protocol(client);
    const hex = reply.result.hex orelse return protocol(client);
    if (n > length or hex.len != 2 * n) return protocol(client);
    _ = std.fmt.hexToBytes(data[0..n], hex) catch return protocol(client);
    count.* = n;
    return 0;
}
