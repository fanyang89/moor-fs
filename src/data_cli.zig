const std = @import("std");
const nas = @import("nas_fs");
const zli = @import("zli");
const m = nas.metadata;
const objects = nas.objects;
const Upload = struct { request_id: u64, inode: u64, version_id: u64, expected_version: u64, backends: [2]u64 };

fn query(ctx: zli.CommandContext, comptime T: type, method: []const u8, value: anytype) !std.json.Parsed(T) {
    const request = try std.json.Stringify.valueAlloc(ctx.allocator, value, .{});
    defer ctx.allocator.free(request);
    const response = try nas.runtime.call(ctx.allocator, ctx.getArg("endpoint").?, method, request);
    defer ctx.allocator.free(response);
    return std.json.parseFromSlice(T, ctx.allocator, response, .{ .allocate = .alloc_always });
}

fn mappings(ctx: zli.CommandContext) !std.json.Parsed([]objects.Mapping) {
    return objects.loadMappings(ctx.allocator, ctx.io, ctx.getArg("config").?);
}

fn publish(ctx: zli.CommandContext, request: m.Request) !void {
    const result = try query(ctx, m.Result, "Apply", request);
    defer result.deinit();
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, result.value, .{});
    defer ctx.allocator.free(json);
    try ctx.writer.print("{s}\n", .{json});
}

pub fn put(ctx: zli.CommandContext) !void {
    const input = try std.json.parseFromSlice(Upload, ctx.allocator, ctx.getArg("json").?, .{});
    defer input.deinit();
    const upload = input.value;
    if (upload.request_id == 0 or upload.version_id == 0 or upload.inode <= m.root_id) return error.InvalidRequest;
    const config = try mappings(ctx);
    defer config.deinit();
    const source = try std.Io.Dir.cwd().openFile(ctx.io, ctx.getArg("source").?, .{ .allow_directory = false });
    defer source.close(ctx.io);
    const digest = try objects.hash(ctx.io, source);
    const version: m.Version = .{ .id = upload.version_id, .inode = upload.inode, .size = digest.size, .sha256 = digest.sha256, .backends = upload.backends };
    const request: m.Request = .{ .request_id = upload.request_id, .command = .{ .publish = .{ .expected_version = upload.expected_version, .version = version } } };
    const old = try query(ctx, ?m.Version, "Version", .{ .id = version.id });
    defer old.deinit();
    if (old.value) |existing| {
        if (!std.meta.eql(existing, version)) return error.VersionConflict;
        // A previous attempt may have committed but lost its response.
        return publish(ctx, request);
    }
    const node = try query(ctx, ?m.Node, "Get", .{ .id = upload.inode });
    defer node.deinit();
    var backends: [2]m.Backend = undefined;
    var count: usize = 0;
    for (upload.backends) |id| {
        if (id == 0) continue;
        const backend = try query(ctx, ?m.Backend, "Backend", .{ .id = id });
        defer backend.deinit();
        backends[count] = backend.value orelse return error.BackendNotFound;
        count += 1;
    }
    const status = m.publicationStatus(node.value orelse return error.NotFound, request.command.publish, backends[0..count]);
    if (status != .ok) {
        std.log.err("publication preflight: {s}", .{@tagName(status)});
        return error.InvalidPublication;
    }
    var stores: [2]objects.Store = undefined;
    var opened: usize = 0;
    defer for (stores[0..opened]) |store| store.close();
    for (upload.backends[0..count]) |id| {
        stores[opened] = try objects.openMapped(ctx.io, config.value, id, true);
        opened += 1;
    }
    if (opened == 2) {
        const first = try stores[0].root.realPathFileAlloc(ctx.io, ".", ctx.allocator);
        defer ctx.allocator.free(first);
        const second = try stores[1].root.realPathFileAlloc(ctx.io, ".", ctx.allocator);
        defer ctx.allocator.free(second);
        if (std.mem.eql(u8, first, second)) return error.DuplicateBackendRoot;
    }
    for (stores[0..opened]) |store| try store.put(source, version);
    // No object is removed after this point: an RPC failure may hide a commit.
    try publish(ctx, request);
}

pub fn initialize(ctx: zli.CommandContext) !void {
    const id = try std.fmt.parseUnsigned(u64, ctx.getArg("id").?, 10);
    if (id == 0) return error.InvalidRequest;
    const config = try mappings(ctx);
    defer config.deinit();
    const backend = try query(ctx, ?m.Backend, "Backend", .{ .id = id });
    defer backend.deinit();
    const registered = backend.value orelse return error.BackendNotFound;
    const store = try objects.openMapped(ctx.io, config.value, id, true);
    defer store.close();
    const import = try store.root.openDir(ctx.io, "import", .{ .follow_symlinks = false, .iterate = true });
    defer import.close(ctx.io);
    try objects.syncDir(ctx.io, import);
    try objects.syncDir(ctx.io, store.staging);
    try objects.syncDir(ctx.io, store.objects);
    try objects.syncDir(ctx.io, store.root);
    try ctx.writer.print("{{\"backend\":{d},\"failure_domain\":{d},\"initialized\":true}}\n", .{ id, registered.failure_domain });
}

fn currentVersion(ctx: zli.CommandContext, id: u64) !m.Version {
    const node = try query(ctx, ?m.Node, "Get", .{ .id = id });
    defer node.deinit();
    const file = node.value orelse return error.NotFound;
    if (file.kind != .file) return error.NotFile;
    if (file.current_version == 0) return error.NoPublishedVersion;
    const record = try query(ctx, ?m.Version, "Version", .{ .id = file.current_version });
    defer record.deinit();
    const version = record.value orelse return error.VersionNotFound;
    if (version.inode != id) return error.InvalidVersion;
    return version;
}

pub fn get(ctx: zli.CommandContext) !void {
    const id = try std.fmt.parseUnsigned(u64, ctx.getArg("id").?, 10);
    const config = try mappings(ctx);
    defer config.deinit();
    const version = try currentVersion(ctx, id);
    for (version.backends) |backend| {
        if (backend == 0) continue;
        const store = objects.openMapped(ctx.io, config.value, backend, false) catch |err| {
            std.log.warn("backend {d}: {s}", .{ backend, @errorName(err) });
            continue;
        };
        defer store.close();
        const source = store.openVerified(version) catch |err| {
            std.log.warn("backend {d}: {s}", .{ backend, @errorName(err) });
            continue;
        };
        defer source.close(ctx.io);
        try objects.exportFile(ctx.io, source, ctx.getArg("destination").?, version);
        try ctx.writer.print("{{\"inode\":{d},\"version\":{d},\"backend\":{d},\"size\":{d}}}\n", .{ id, version.id, backend, version.size });
        return;
    }
    return error.NoHealthyReplica;
}

const ReplicaCheck = struct {
    backend: u64,
    status: enum { healthy, missing, corrupt, unavailable, unconfigured },
    reason: ?[]const u8 = null,
};

pub fn repair(ctx: zli.CommandContext) !void {
    const replace_corrupt = ctx.flag("replace-corrupt", bool);
    const id = try std.fmt.parseUnsigned(u64, ctx.getArg("id").?, 10);
    const backend = try std.fmt.parseUnsigned(u64, ctx.getArg("backend").?, 10);
    const config = try mappings(ctx);
    defer config.deinit();
    const version = try currentVersion(ctx, id);
    if (backend == 0 or std.mem.indexOfScalar(u64, &version.backends, backend) == null) return error.ReplicaNotDeclared;
    // Do not initialize an absent mount or change immutable replica declarations.
    const target = try objects.openMapped(ctx.io, config.value, backend, false);
    defer target.close();
    const existing: ?std.Io.File = target.openRepairTarget(version) catch |err| switch (err) {
        error.FileNotFound => null,
        error.ChecksumMismatch => if (replace_corrupt) null else return err,
        else => return err,
    };
    if (existing) |file| {
        defer file.close(ctx.io);
        // A previous attempt may have installed bytes but died before directory sync.
        try file.sync(ctx.io);
        try objects.syncDir(ctx.io, target.objects);
        try objects.syncDir(ctx.io, target.staging);
        try repairResult(ctx, version, backend, null);
        return;
    }
    for (version.backends) |source_backend| {
        if (source_backend == 0 or source_backend == backend) continue;
        const store = objects.openMapped(ctx.io, config.value, source_backend, false) catch continue;
        defer store.close();
        const source = store.openVerified(version) catch continue;
        defer source.close(ctx.io);
        // Both paths verify staging before installation; replacement is explicit.
        // A concurrent publication or unlink cannot change this version's object name.
        if (replace_corrupt) try target.repairCorrupt(source, version) else try target.put(source, version);
        try repairResult(ctx, version, backend, source_backend);
        return;
    }
    return error.NoHealthyReplica;
}

fn repairResult(ctx: zli.CommandContext, version: m.Version, backend: u64, source_backend: ?u64) !void {
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .inode = version.inode,
        .version = version.id,
        .backend = backend,
        .source_backend = source_backend,
        .status = if (source_backend != null) "repaired" else "already_healthy",
    }, .{});
    defer ctx.allocator.free(json);
    try ctx.writer.print("{s}\n", .{json});
}

fn checkReplica(io: std.Io, config: []const objects.Mapping, backend: u64, version: m.Version) ReplicaCheck {
    const mapping = objects.mappingFor(config, backend) catch |err| return .{ .backend = backend, .status = .unconfigured, .reason = @errorName(err) };
    const store = objects.Store.openMapping(io, mapping, false) catch |err| return .{ .backend = backend, .status = .unavailable, .reason = @errorName(err) };
    defer store.close();
    const file = store.openVerified(version) catch |err| return .{
        .backend = backend,
        .status = switch (err) {
            error.FileNotFound => .missing,
            error.ChecksumMismatch => .corrupt,
            else => .unavailable,
        },
        .reason = @errorName(err),
    };
    file.close(io);
    return .{ .backend = backend, .status = .healthy };
}

pub fn check(ctx: zli.CommandContext) !void {
    const id = try std.fmt.parseUnsigned(u64, ctx.getArg("id").?, 10);
    const config = try mappings(ctx);
    defer config.deinit();
    // Pin one metadata version for the entire scan, even if publication races it.
    const version = try currentVersion(ctx, id);
    var replicas: [2]ReplicaCheck = undefined;
    var count: usize = 0;
    var healthy: usize = 0;
    for (version.backends) |backend| {
        if (backend == 0) continue;
        replicas[count] = checkReplica(ctx.io, config.value, backend, version);
        if (replicas[count].status == .healthy) healthy += 1;
        count += 1;
    }
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .inode = id,
        .version = version.id,
        .size = version.size,
        .healthy_replicas = healthy,
        .all_healthy = healthy == count,
        .replicas = replicas[0..count],
    }, .{});
    defer ctx.allocator.free(json);
    try ctx.writer.print("{s}\n", .{json});
}
