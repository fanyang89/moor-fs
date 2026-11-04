const std = @import("std");
const m = @import("metadata.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const mount = @import("backend_mount.zig");

pub const Digest = struct { size: u64, sha256: [32]u8 };
pub const Mapping = struct { id: u64, root: []const u8, mount: ?mount.Identity = null, allow_local: bool = false };

fn shareName(source: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, source, "//")) return null;
    const separator = std.mem.indexOfScalarPos(u8, source, 2, '/') orelse return null;
    if (separator == 2 or separator + 1 == source.len) return null;
    const end = std.mem.indexOfScalarPos(u8, source, separator + 1, '/') orelse source.len;
    if (end == separator + 1) return null;
    return source[separator + 1 .. end];
}

pub fn loadMappings(gpa: std.mem.Allocator, io: Io, path: []const u8) !std.json.Parsed([]Mapping) {
    const data = try Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(data);
    const parsed = try std.json.parseFromSlice([]Mapping, gpa, data, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.len == 0 or parsed.value.len > m.max_backends) return error.InvalidBackendConfig;
    for (parsed.value, 0..) |mapping, i| {
        if (mapping.id == 0 or !std.fs.path.isAbsolute(mapping.root) or std.mem.indexOfScalar(u8, mapping.root, 0) != null) return error.InvalidBackendConfig;
        if ((mapping.mount != null) == mapping.allow_local) return error.BackendIdentityRequired;
        if (mapping.mount) |identity| {
            if (!std.fs.path.isAbsolute(identity.mountpoint) or shareName(identity.source) == null or identity.address.len == 0) return error.InvalidBackendConfig;
            for ([_][]const u8{ identity.mountpoint, identity.source, identity.address }) |value| if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidBackendConfig;
        }
        for (parsed.value[0..i]) |previous| {
            if (mapping.id == previous.id or std.mem.eql(u8, mapping.root, previous.root)) return error.InvalidBackendConfig;
            if (mapping.mount) |a| {
                if (previous.mount) |b| {
                    if (std.ascii.eqlIgnoreCase(shareName(a.source).?, shareName(b.source).?) and std.mem.eql(u8, a.address, b.address)) return error.DuplicateBackendMount;
                }
            }
        }
    }
    return parsed;
}

pub fn mappingFor(config: []const Mapping, id: u64) !Mapping {
    for (config) |mapping| if (mapping.id == id) return mapping;
    return error.BackendNotConfigured;
}

pub fn openMapped(io: Io, config: []const Mapping, id: u64, initialize: bool) !Store {
    return Store.openMapping(io, try mappingFor(config, id), initialize);
}

pub fn hash(io: Io, file: File) !Digest {
    return transfer(io, file, null);
}

fn transfer(io: Io, source: File, destination: ?File) !Digest {
    const before = try source.stat(io);
    if (before.kind != .file or before.size > std.math.maxInt(i64)) return error.InvalidSource;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        const count = try source.readPositional(io, &.{buffer[0..@min(buffer.len, before.size - offset)]}, offset);
        if (count == 0) return error.SourceChanged;
        hasher.update(buffer[0..count]);
        if (destination) |file| try file.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
    }
    const after = try source.stat(io);
    if (before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime)) return error.SourceChanged;
    return .{ .size = offset, .sha256 = hasher.finalResult() };
}

pub fn matches(digest: Digest, version: m.Version) bool {
    return digest.size == version.size and std.mem.eql(u8, &digest.sha256, &version.sha256);
}

pub fn name(buffer: *[96]u8, version: m.Version) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}-{s}", .{ version.id, std.fmt.bytesToHex(version.sha256, .lower) });
}

pub fn syncDir(io: Io, dir: Dir) !void {
    // Linux directory descriptors support fsync; unsupported backends fail closed.
    const file: File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

pub const Store = struct {
    io: Io,
    root: Dir,
    staging: Dir,
    objects: Dir,
    identity: ?mount.Identity = null,

    pub fn open(io: Io, path: []const u8, initialize: bool) !Store {
        return openMapping(io, .{ .id = 1, .root = path, .allow_local = true }, initialize);
    }

    pub fn openMapping(io: Io, mapping: Mapping, initialize: bool) !Store {
        if ((mapping.mount != null) == mapping.allow_local) return error.BackendIdentityRequired;
        const root = try Dir.cwd().openDir(io, mapping.root, .{ .follow_symlinks = false, .iterate = true });
        errdefer root.close(io);
        const mount_id = if (mapping.mount) |identity| try mount.validate(io, root, identity) else null;
        if (initialize) {
            for ([_][]const u8{ "import", "staging", "objects" }) |child| {
                root.createDir(io, child, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }
            try syncDir(io, root);
        }
        const staging = try root.openDir(io, "staging", .{ .follow_symlinks = false, .iterate = true });
        errdefer staging.close(io);
        const objects = try root.openDir(io, "objects", .{ .follow_symlinks = false, .iterate = true });
        errdefer objects.close(io);
        if (mount_id) |id| {
            if (try mount.mountId(io, staging) != id or try mount.mountId(io, objects) != id) return error.BackendMountMismatch;
        }
        return .{ .io = io, .root = root, .staging = staging, .objects = objects, .identity = mapping.mount };
    }

    pub fn close(self: Store) void {
        self.objects.close(self.io);
        self.staging.close(self.io);
        self.root.close(self.io);
    }

    pub fn openVerified(self: Store, version: m.Version) !File {
        var buffer: [96]u8 = undefined;
        const file = try self.objects.openFile(self.io, try name(&buffer, version), .{ .follow_symlinks = false, .allow_directory = false });
        errdefer file.close(self.io);
        if (!matches(try hash(self.io, file), version)) return error.ChecksumMismatch;
        return file;
    }

    pub fn openRepairTarget(self: Store, version: m.Version) !File {
        // A competing atomic replacement can change the old inode's ctime while
        // it is hashed. Reopen once to verify the now-current target, never its source.
        return self.openVerified(version) catch |err| switch (err) {
            error.SourceChanged => self.openVerified(version),
            else => return err,
        };
    }

    pub fn put(self: Store, source: File, version: m.Version) !void {
        return self.install(source, version, false);
    }

    /// Restore only this immutable version's bytes, never mutate an open object in place.
    pub fn repairCorrupt(self: Store, source: File, version: m.Version) !void {
        return self.install(source, version, true);
    }

    fn install(self: Store, source: File, version: m.Version, replace_corrupt: bool) !void {
        if (self.identity) |identity| _ = try mount.validate(self.io, self.root, identity);
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const temporary = std.fmt.bytesToHex(random, .lower);
        const file = try self.staging.createFile(self.io, &temporary, .{ .read = true, .exclusive = true });
        defer file.close(self.io);
        defer self.staging.deleteFile(self.io, &temporary) catch {};
        if (!matches(try transfer(self.io, source, file), version)) return error.SourceChanged;
        try file.sync(self.io);
        // Read back each replica before making its object name visible.
        if (!matches(try hash(self.io, file), version)) return error.ChecksumMismatch;
        if (self.identity) |identity| _ = try mount.validate(self.io, self.root, identity);
        var buffer: [96]u8 = undefined;
        self.staging.renamePreserve(&temporary, self.objects, try name(&buffer, version), self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Recheck after staging: another repair may already have fixed the target.
                const existing: ?File = (if (replace_corrupt) self.openRepairTarget(version) else self.openVerified(version)) catch |verify_error| switch (verify_error) {
                    error.ChecksumMismatch => if (replace_corrupt) null else return verify_error,
                    else => return verify_error,
                };
                if (existing) |healthy| {
                    defer healthy.close(self.io);
                    try healthy.sync(self.io);
                } else {
                    // All installers for this name must supply the same size/digest.
                    // A concurrent healthy replacement is therefore byte-equivalent.
                    @import("repair_fault.zig").checkpoint(.before_replace);
                    try self.staging.rename(&temporary, self.objects, try name(&buffer, version), self.io);
                    @import("repair_fault.zig").checkpoint(.after_replace);
                }
            },
            else => return err,
        };
        try syncDir(self.io, self.objects);
        try syncDir(self.io, self.staging);
        if (replace_corrupt) @import("repair_fault.zig").checkpoint(.after_sync);
    }
};

/// Destination must be new. Never replace an existing user file.
pub fn exportFile(io: Io, source: File, destination: []const u8, version: m.Version) !void {
    const parent = std.fs.path.dirname(destination) orelse ".";
    const basename = std.fs.path.basename(destination);
    const dir = try Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    var buffer: [64]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&buffer, ".nas-fs-{s}", .{std.fmt.bytesToHex(random, .lower)});
    const file = try dir.createFile(io, temporary, .{ .exclusive = true });
    defer file.close(io);
    defer dir.deleteFile(io, temporary) catch {};
    if (!matches(try transfer(io, source, file), version)) return error.ChecksumMismatch;
    try file.sync(io);
    try dir.renamePreserve(temporary, dir, basename, io);
    try syncDir(io, dir);
}
