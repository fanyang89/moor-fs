const std = @import("std");
const nas = @import("nas_fs");
const m = nas.metadata;
const objects = nas.objects;
const allocator = std.heap.smp_allocator;

const Entry = extern struct { id: u64, parent: u64, size: u64, directory: c_int, name: [256]u8 };
const Api = extern struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, u64, ?[*:0]const u8, *Entry) callconv(.c) c_int,
    list: *const fn (*anyopaque, u64, *?[*]Entry, *usize) callconv(.c) c_int,
    free: *const fn ([*]Entry, usize) callconv(.c) void,
    open: *const fn (*anyopaque, u64, *Entry, *c_int) callconv(.c) c_int,
    writable: c_int,
    prepare: *const fn (*anyopaque, u64, *Entry, *c_int, *u64) callconv(.c) c_int,
    commit: *const fn (*anyopaque, u64, c_int, *u64, *u64) callconv(.c) c_int,
    create: *const fn (*anyopaque, u64, [*:0]const u8, c_int, *Entry) callconv(.c) c_int,
    remove: *const fn (*anyopaque, u64, [*:0]const u8, c_int) callconv(.c) c_int,
    rename: *const fn (*anyopaque, u64, [*:0]const u8, u64, [*:0]const u8) callconv(.c) c_int,
};
extern fn nas_fuse_run(path: [*:0]const u8, api: *const Api) c_int;

const Client = struct {
    endpoints: []const u8,
    io: std.Io,
    mappings: []const objects.Mapping,
    write_backends: [2]u64 = .{ 0, 0 },

    fn randomId(self: *Client) u64 {
        var id: u64 = 0;
        while (id == 0) self.io.random(std.mem.asBytes(&id));
        return id;
    }

    fn apply(self: *Client, command: m.Command) !u64 {
        if (self.write_backends[0] == 0) return error.ReadOnly;
        const result = try self.query(m.Result, "Apply", m.Request{ .request_id = self.randomId(), .command = command });
        defer result.deinit();
        try checkStatus(result.value.status);
        return result.value.inode;
    }

    fn prepareFile(self: *Client, id: u64, out: *Entry, fd: *c_int, expected: *u64) !void {
        const record = try self.query(?m.Node, "Get", .{ .id = id });
        defer record.deinit();
        const node = record.value orelse return error.NotFound;
        if (node.kind != .file) return error.IsDirectory;
        if (node.replicas != .two) return error.InvalidReplicaPolicy;
        expected.* = node.current_version;
        out.* = try entry(node);
        fd.* = -1;
        if (try self.getVersion(node)) |version| {
            out.size = version.size;
            for (version.backends) |backend| {
                const store = objects.openMapped(self.io, self.mappings, backend, false) catch continue;
                defer store.close();
                const file = store.openVerified(version) catch continue;
                fd.* = file.handle;
                return;
            }
            return error.NoHealthyReplica;
        }
    }

    fn publishFile(self: *Client, id: u64, fd: c_int, expected: *u64, size: *u64) !void {
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        const digest = try objects.hash(self.io, file);
        const version: m.Version = .{ .id = self.randomId(), .inode = id, .size = digest.size, .sha256 = digest.sha256, .backends = self.write_backends };
        for (self.write_backends, 0..) |backend, i| {
            const store = try objects.openMapped(self.io, self.mappings, backend, false);
            defer store.close();
            try store.put(file, version);
            if (i == 0) @import("write_fault.zig").checkpoint(.first_replica, version.size);
        }
        @import("write_fault.zig").checkpoint(.both_replicas, version.size);
        _ = try self.apply(.{ .publish = .{ .expected_version = expected.*, .version = version } });
        @import("write_fault.zig").checkpoint(.published, version.size);
        expected.* = version.id;
        size.* = version.size;
    }

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
        const node = result.value orelse return error.NotFound;
        var out = try entry(node);
        if (try self.getVersion(node)) |version| out.size = version.size;
        return out;
    }

    fn getVersion(self: *Client, node: m.Node) !?m.Version {
        if (node.kind == .directory or node.current_version == 0) return null;
        const record = try self.query(?m.Version, "Version", .{ .id = node.current_version });
        defer record.deinit();
        const value = record.value orelse return error.InvalidResponse;
        if (value.inode != node.id or value.size > std.math.maxInt(i64)) return error.InvalidResponse;
        return value;
    }

    fn openFile(self: *Client, id: u64, out: *Entry) !std.Io.File {
        if (self.mappings.len == 0) return error.NoBackendConfig;
        const record = try self.query(?m.Node, "Get", .{ .id = id });
        defer record.deinit();
        const node = record.value orelse return error.NotFound;
        if (node.kind == .directory) return error.IsDirectory;
        const version = (try self.getVersion(node)) orelse return error.NoPublishedVersion;
        out.* = try entry(node);
        out.size = version.size;
        for (version.backends) |backend| {
            if (backend == 0) continue;
            const store = objects.openMapped(self.io, self.mappings, backend, false) catch continue;
            defer store.close();
            return store.openVerified(version) catch continue;
        }
        return error.NoHealthyReplica;
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
    var result: Entry = .{ .id = node.id, .parent = node.parent, .size = 0, .directory = @intFromBool(node.kind == .directory), .name = @splat(0) };
    @memcpy(result.name[0..node.name.len], node.name);
    return result;
}

fn errno(err: anyerror) c_int {
    return switch (err) {
        error.NotFound => 2,
        error.NotDirectory => 20,
        error.OutOfMemory => 12,
        error.DirectoryChanged => 11,
        error.IsDirectory => 21,
        error.NoPublishedVersion => 61,
        error.NoBackendConfig => 95,
        error.ReadOnly => 30,
        error.AlreadyExists => 17,
        error.NotEmpty => 39,
        error.InvalidName, error.InvalidReplicaPolicy => 22,
        error.VersionConflict => 11,
        error.CapacityExceeded => 28,
        else => 5,
    };
}

fn checkStatus(status: m.Status) !void {
    return switch (status) {
        .ok => {},
        .not_found => error.NotFound,
        .already_exists => error.AlreadyExists,
        .not_directory => error.NotDirectory,
        .not_file => error.IsDirectory,
        .not_empty => error.NotEmpty,
        .invalid_name, .cycle, .root_protected => error.InvalidName,
        .version_conflict => error.VersionConflict,
        .capacity_exceeded => error.CapacityExceeded,
        else => error.InvalidResponse,
    };
}

fn prepare(context: *anyopaque, id: u64, out: *Entry, fd: *c_int, expected: *u64) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    client.prepareFile(id, out, fd, expected) catch |err| return errno(err);
    return 0;
}

fn commit(context: *anyopaque, id: u64, fd: c_int, expected: *u64, size: *u64) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    client.publishFile(id, fd, expected, size) catch |err| {
        std.log.err("publish inode {d}, expected version {d}: {s}", .{ id, expected.*, @errorName(err) });
        return errno(err);
    };
    return 0;
}

fn create(context: *anyopaque, parent: u64, name: [*:0]const u8, directory: c_int, out: *Entry) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    const id = client.apply(.{ .create = .{ .parent = parent, .name = std.mem.span(name), .kind = if (directory != 0) .directory else .file, .replicas = .two } }) catch |err| return errno(err);
    out.* = client.getNode(id, null) catch |err| return errno(err);
    return 0;
}

fn remove(context: *anyopaque, parent: u64, name: [*:0]const u8, directory: c_int) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = client.apply(.{ .remove_entry = .{ .parent = parent, .name = std.mem.span(name), .kind = if (directory != 0) .directory else .file } }) catch |err| return errno(err);
    return 0;
}

fn rename(context: *anyopaque, parent: u64, name: [*:0]const u8, new_parent: u64, new_name: [*:0]const u8) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = client.apply(.{ .rename_entry = .{ .parent = parent, .name = std.mem.span(name), .new_parent = new_parent, .new_name = std.mem.span(new_name) } }) catch |err| return errno(err);
    return 0;
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

fn open(context: *anyopaque, id: u64, out: *Entry, fd: *c_int) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context));
    const file = client.openFile(id, out) catch |err| return errno(err);
    // Ownership transfers to the C bridge, which closes on release or unmount.
    fd.* = file.handle;
    return 0;
}

pub fn mount(gpa: std.mem.Allocator, io: std.Io, endpoints: []const u8, path: []const u8, config: []const u8, write_config: []const u8) !void {
    const mappings = if (config.len == 0) null else try objects.loadMappings(gpa, io, config);
    defer if (mappings) |parsed| parsed.deinit();
    var client: Client = .{ .endpoints = endpoints, .io = io, .mappings = if (mappings) |parsed| parsed.value else &.{} };
    if (write_config.len != 0) {
        var ids = std.mem.splitScalar(u8, write_config, ',');
        var domains: [2]u64 = undefined;
        var paths: [2][:0]u8 = undefined;
        var count: usize = 0;
        defer for (paths[0..count]) |p| gpa.free(p);
        for (0..2) |i| {
            const id = try std.fmt.parseUnsigned(u64, ids.next() orelse return error.InvalidReplicaPolicy, 10);
            const backend = try client.query(?m.Backend, "Backend", .{ .id = id });
            defer backend.deinit();
            domains[i] = (backend.value orelse return error.BackendNotFound).failure_domain;
            const store = try objects.openMapped(io, client.mappings, id, false);
            defer store.close();
            paths[i] = try store.root.realPathFileAlloc(io, ".", gpa);
            count += 1;
            client.write_backends[i] = id;
        }
        if (ids.next() != null or domains[0] == domains[1] or std.mem.eql(u8, paths[0], paths[1])) return error.InvalidReplicaPolicy;
    }
    _ = try client.getNode(1, null);
    const mountpoint = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(mountpoint);
    const api: Api = .{ .context = &client, .get = get, .list = list, .free = free, .open = open, .writable = @intFromBool(write_config.len != 0), .prepare = prepare, .commit = commit, .create = create, .remove = remove, .rename = rename };
    if (nas_fuse_run(mountpoint, &api) != 0) return error.FuseFailed;
}
