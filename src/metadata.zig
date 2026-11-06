const std = @import("std");

pub const root_id: u64 = 1;
pub const max_nodes = 4096;
pub const max_receipts = 8192;
pub const max_backends = 64;
pub const max_versions = 2048;
pub const Backend = struct { id: u64, failure_domain: u64 };
pub const Version = struct {
    id: u64,
    inode: u64,
    size: u64,
    sha256: [32]u8,
    backends: [2]u64,

    pub fn jsonStringify(self: Version, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        // Hash bytes must remain numeric even when they happen to be valid UTF-8.
        var bytes: [32]u16 = undefined;
        for (self.sha256, 0..) |byte, i| bytes[i] = byte;
        try writer.write(.{ .id = self.id, .inode = self.inode, .size = self.size, .sha256 = bytes, .backends = self.backends });
    }
};
pub const Publication = struct { expected_version: u64, version: Version };
/// The last checkpoint recorded in Raft, not a live view of in-flight writes.
pub const MutableFile = struct {
    generation: u64,
    next_sequence: u64,
    size: u64,
    backends: [2]u64,
};
pub const MutableUpdate = union(enum) {
    attach: struct { inode: u64, expected_version: u64, file: MutableFile },
    checkpoint: struct { inode: u64, generation: u64, expected_sequence: u64, next_sequence: u64, size: u64 },
};
pub const Replicas = enum { one, two };
pub const Kind = enum { directory, file };
pub const Entry = struct { inode: u64, parent: u64, name: []const u8 };
pub const RenameChecked = struct { source: Entry, parent: u64, name: []const u8 };
pub const max_path_guards = 32;
pub const GuardedChange = struct {
    ancestors: []const Entry,
    mutation: union(enum) { rename: RenameChecked, remove: Entry },
};

/// A bounded proof must connect both affected parents to the immutable root.
pub fn validPathGuards(change: GuardedChange) bool {
    if (change.ancestors.len > max_path_guards) return false;
    for (change.ancestors, 0..) |entry, i| {
        if (entry.inode <= root_id or !validName(entry.name)) return false;
        for (change.ancestors[0..i]) |earlier| if (entry.inode == earlier.inode) return false;
    }
    const parents: [2]u64 = switch (change.mutation) {
        .rename => |op| .{ op.source.parent, op.parent },
        .remove => |op| .{ op.parent, root_id },
    };
    for (parents) |parent| {
        var current = parent;
        var steps: usize = 0;
        while (current != root_id) {
            if (steps >= change.ancestors.len) return false;
            const entry = for (change.ancestors) |entry| {
                if (entry.inode == current) break entry;
            } else return false;
            current = entry.parent;
            steps += 1;
        }
    }
    return true;
}
pub const Node = struct {
    id: u64,
    parent: u64,
    name: []const u8,
    kind: Kind,
    replicas: Replicas,
    current_version: u64 = 0,
    mutable_file: ?MutableFile = null,
};
pub const Command = union(enum) {
    create: struct { parent: u64, name: []const u8, kind: Kind, replicas: ?Replicas = null },
    rename: struct { id: u64, parent: u64, name: []const u8 },
    remove: struct { id: u64 },
    remove_entry: struct { parent: u64, name: []const u8, kind: Kind },
    rename_entry: struct { parent: u64, name: []const u8, new_parent: u64, new_name: []const u8 },
    set_replicas: struct { id: u64, replicas: Replicas },
    register_backend: Backend,
    publish: Publication,
    mutable_file: MutableUpdate,
    rename_checked: RenameChecked,
    remove_checked: Entry,
    path_guarded: GuardedChange,
};
pub const Request = struct { version: u32 = 1, request_id: u64, command: Command };
pub const Status = enum(u8) {
    ok = 0,
    not_found = 1,
    already_exists = 2,
    not_directory = 3,
    not_empty = 4,
    invalid_name = 5,
    root_protected = 6,
    cycle = 7,
    invalid_request = 8,
    request_conflict = 9,
    capacity_exceeded = 10,
    unsupported_version = 11,
    not_file = 12,
    version_conflict = 13,
    invalid_version = 14,
    replica_mismatch = 15,
    backend_not_found = 16,
    same_failure_domain = 17,
    storage_conflict = 18,
    sequence_conflict = 19,
    entry_conflict = 20,
};
pub const Result = struct { status: Status, inode: u64 = 0 };
pub const Receipt = struct { request_id: u64, digest: [32]u8, result: Result };
pub const Snapshot = struct {
    next_id: u64,
    nodes: []const Node,
    receipts: []const Receipt,
    backends: []const Backend = &.{},
    versions: []const Version = &.{},
};

pub const State = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    receipts: std.ArrayList(Receipt) = .empty,
    backends: std.ArrayList(Backend) = .empty,
    versions: std.ArrayList(Version) = .empty,
    next_id: u64 = root_id + 1,

    pub fn init(allocator: std.mem.Allocator) !State {
        var self: State = .{ .allocator = allocator };
        const name = try allocator.dupe(u8, "");
        errdefer allocator.free(name);
        try self.nodes.append(allocator, .{
            .id = root_id,
            .parent = 0,
            .name = name,
            .kind = .directory,
            .replicas = .two,
        });
        return self;
    }

    pub fn deinit(self: *State) void {
        for (self.nodes.items) |node| self.allocator.free(node.name);
        self.nodes.deinit(self.allocator);
        self.receipts.deinit(self.allocator);
        self.backends.deinit(self.allocator);
        self.versions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *const State, id: u64) ?Node {
        const i = self.find(id) orelse return null;
        return self.nodes.items[i];
    }

    pub fn lookup(self: *const State, parent: u64, name: []const u8) ?Node {
        for (self.nodes.items) |node| {
            if (node.parent == parent and std.ascii.eqlIgnoreCase(node.name, name)) return node;
        }
        return null;
    }

    pub fn apply(self: *State, request: Request) std.mem.Allocator.Error!Result {
        if (request.version != 1) return .{ .status = .unsupported_version };
        if (request.request_id == 0) return .{ .status = .invalid_request };
        const digest = try requestDigest(self.allocator, request);
        for (self.receipts.items) |receipt| {
            if (receipt.request_id == request.request_id) {
                if (!std.mem.eql(u8, &receipt.digest, &digest)) return .{ .status = .request_conflict };
                return receipt.result;
            }
        }
        if (self.receipts.items.len == max_receipts) return .{ .status = .capacity_exceeded };
        try self.receipts.ensureUnusedCapacity(self.allocator, 1);
        const result = try self.execute(request.command);
        self.receipts.appendAssumeCapacity(.{
            .request_id = request.request_id,
            .digest = digest,
            .result = result,
        });
        return result;
    }

    fn execute(self: *State, command: Command) std.mem.Allocator.Error!Result {
        switch (command) {
            .path_guarded => |c| {
                if (!validPathGuards(c)) return .{ .status = .invalid_request };
                for (c.ancestors) |entry| {
                    const node = self.get(entry.inode) orelse return .{ .status = .entry_conflict };
                    if (node.kind != .directory or node.parent != entry.parent or !std.mem.eql(u8, node.name, entry.name)) return .{ .status = .entry_conflict };
                }
                return self.execute(switch (c.mutation) {
                    .rename => |op| .{ .rename_checked = op },
                    .remove => |op| .{ .remove_checked = op },
                });
            },
            .rename_checked => |c| {
                const node = self.get(c.source.inode) orelse return .{ .status = .entry_conflict };
                if (node.parent != c.source.parent or !std.mem.eql(u8, node.name, c.source.name)) return .{ .status = .entry_conflict };
                return self.execute(.{ .rename = .{ .id = c.source.inode, .parent = c.parent, .name = c.name } });
            },
            .remove_checked => |c| {
                const node = self.get(c.inode) orelse return .{ .status = .entry_conflict };
                if (node.parent != c.parent or !std.mem.eql(u8, node.name, c.name)) return .{ .status = .entry_conflict };
                return self.execute(.{ .remove = .{ .id = c.inode } });
            },
            .remove_entry => |c| {
                if (!validName(c.name)) return .{ .status = .invalid_name };
                const node = self.lookup(c.parent, c.name) orelse return .{ .status = .not_found };
                if (node.kind != c.kind) return .{ .status = if (c.kind == .file) .not_file else .not_directory };
                return self.execute(.{ .remove = .{ .id = node.id } });
            },
            .rename_entry => |c| {
                if (!validName(c.name)) return .{ .status = .invalid_name };
                const node = self.lookup(c.parent, c.name) orelse return .{ .status = .not_found };
                return self.execute(.{ .rename = .{ .id = node.id, .parent = c.new_parent, .name = c.new_name } });
            },
            .create => |c| {
                if (!validName(c.name)) return .{ .status = .invalid_name };
                const parent = self.get(c.parent) orelse return .{ .status = .not_found };
                if (parent.kind != .directory) return .{ .status = .not_directory };
                if (self.lookup(c.parent, c.name) != null) return .{ .status = .already_exists };
                if (self.nodes.items.len == max_nodes or self.next_id == std.math.maxInt(u64))
                    return .{ .status = .capacity_exceeded };
                const name = try self.allocator.dupe(u8, c.name);
                errdefer self.allocator.free(name);
                try self.nodes.ensureUnusedCapacity(self.allocator, 1);
                const id = self.next_id;
                self.nodes.appendAssumeCapacity(.{
                    .id = id,
                    .parent = c.parent,
                    .name = name,
                    .kind = c.kind,
                    .replicas = c.replicas orelse parent.replicas,
                });
                self.next_id += 1;
                return .{ .status = .ok, .inode = id };
            },
            .rename => |c| {
                if (c.id == root_id) return .{ .status = .root_protected };
                if (!validName(c.name)) return .{ .status = .invalid_name };
                const i = self.find(c.id) orelse return .{ .status = .not_found };
                const parent = self.get(c.parent) orelse return .{ .status = .not_found };
                if (parent.kind != .directory) return .{ .status = .not_directory };
                if (self.lookup(c.parent, c.name)) |target| {
                    if (target.id != c.id) return .{ .status = .already_exists };
                }
                var ancestor = parent.id;
                while (ancestor != 0) {
                    if (ancestor == c.id) return .{ .status = .cycle };
                    ancestor = self.get(ancestor).?.parent;
                }
                const name = try self.allocator.dupe(u8, c.name);
                self.allocator.free(self.nodes.items[i].name);
                self.nodes.items[i].name = name;
                self.nodes.items[i].parent = c.parent;
                return .{ .status = .ok, .inode = c.id };
            },
            .remove => |c| {
                if (c.id == root_id) return .{ .status = .root_protected };
                const i = self.find(c.id) orelse return .{ .status = .not_found };
                for (self.nodes.items) |node| {
                    if (node.parent == c.id) return .{ .status = .not_empty };
                }
                const node = self.nodes.orderedRemove(i);
                self.allocator.free(node.name);
                return .{ .status = .ok, .inode = c.id };
            },
            .set_replicas => |c| {
                const i = self.find(c.id) orelse return .{ .status = .not_found };
                if (self.nodes.items[i].mutable_file != null and c.replicas != .two) return .{ .status = .replica_mismatch };
                self.nodes.items[i].replicas = c.replicas;
                return .{ .status = .ok, .inode = c.id };
            },
            .register_backend => |backend| {
                if (backend.id == 0 or backend.failure_domain == 0) return .{ .status = .invalid_request };
                for (self.backends.items) |existing| if (existing.id == backend.id) return .{ .status = .already_exists };
                if (self.backends.items.len == max_backends) return .{ .status = .capacity_exceeded };
                try self.backends.append(self.allocator, backend);
                return .{ .status = .ok };
            },
            .publish => |publication| {
                const i = self.find(publication.version.inode) orelse return .{ .status = .not_found };
                const status = publicationStatus(self.nodes.items[i], publication, self.backends.items);
                if (status != .ok) return .{ .status = status };
                for (self.versions.items) |version| if (version.id == publication.version.id) return .{ .status = .version_conflict };
                if (self.versions.items.len == max_versions) return .{ .status = .capacity_exceeded };
                try self.versions.append(self.allocator, publication.version);
                self.nodes.items[i].current_version = publication.version.id;
                return .{ .status = .ok, .inode = publication.version.inode };
            },
            .mutable_file => |update| {
                const id = mutableInode(update);
                const i = self.find(id) orelse return .{ .status = .not_found };
                const status = updateMutable(&self.nodes.items[i], update, self.backends.items);
                return .{ .status = status, .inode = if (status == .ok) id else 0 };
            },
        }
    }

    fn find(self: *const State, id: u64) ?usize {
        for (self.nodes.items, 0..) |node, i| {
            if (node.id == id) return i;
        }
        return null;
    }

    pub fn snapshot(self: *const State) Snapshot {
        return .{ .next_id = self.next_id, .nodes = self.nodes.items, .receipts = self.receipts.items, .backends = self.backends.items, .versions = self.versions.items };
    }

    pub fn restore(allocator: std.mem.Allocator, data: Snapshot) !State {
        try validateSnapshot(data);
        var self: State = .{ .allocator = allocator, .next_id = data.next_id };
        errdefer self.deinit();
        try self.nodes.ensureTotalCapacity(allocator, data.nodes.len);
        for (data.nodes) |node| {
            var copy = node;
            copy.name = try allocator.dupe(u8, node.name);
            self.nodes.appendAssumeCapacity(copy);
        }
        try self.receipts.appendSlice(allocator, data.receipts);
        try self.backends.appendSlice(allocator, data.backends);
        try self.versions.appendSlice(allocator, data.versions);
        return self;
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    return std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

pub fn requestDigest(allocator: std.mem.Allocator, request: Request) ![32]u8 {
    const encoded = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(encoded);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    return digest;
}

pub fn validateSnapshot(data: Snapshot) !void {
    if (data.nodes.len == 0 or data.nodes.len > max_nodes or data.receipts.len > max_receipts) return error.InvalidSnapshot;
    if (data.backends.len > max_backends or data.versions.len > max_versions) return error.InvalidSnapshot;
    for (data.backends, 0..) |backend, i| {
        if (backend.id == 0 or backend.failure_domain == 0) return error.InvalidSnapshot;
        for (data.backends[0..i]) |previous| if (previous.id == backend.id) return error.InvalidSnapshot;
    }
    for (data.versions, 0..) |version, i| {
        if (version.inode >= data.next_id or versionStatus(version, data.backends) != .ok) return error.InvalidSnapshot;
        for (data.nodes) |node| if (node.id == version.inode and node.kind != .file) return error.InvalidSnapshot;
        for (data.versions[0..i]) |previous| if (previous.id == version.id) return error.InvalidSnapshot;
    }
    const root = data.nodes[0];
    if (root.id != root_id or root.parent != 0 or root.name.len != 0 or root.kind != .directory) return error.InvalidSnapshot;
    for (data.nodes, 0..) |node, i| {
        if (node.id == 0 or node.id >= data.next_id) return error.InvalidSnapshot;
        if (node.mutable_file) |file| {
            if (node.kind != .file or node.current_version != 0 or node.replicas != .two or mutableStatus(file, data.backends) != .ok) return error.InvalidSnapshot;
        }
        if (node.current_version != 0) {
            if (node.kind != .file) return error.InvalidSnapshot;
            const version = for (data.versions) |v| {
                if (v.id == node.current_version) break v;
            } else return error.InvalidSnapshot;
            if (version.inode != node.id) return error.InvalidSnapshot;
        }
        if (i != 0 and (!validName(node.name) or node.parent == 0)) return error.InvalidSnapshot;
        for (data.nodes[0..i]) |previous| {
            if (previous.id == node.id) return error.InvalidSnapshot;
            if (previous.parent == node.parent and std.ascii.eqlIgnoreCase(previous.name, node.name)) return error.InvalidSnapshot;
        }
        var parent = node.parent;
        var depth: usize = 0;
        while (parent != 0) : (depth += 1) {
            if (depth >= data.nodes.len) return error.InvalidSnapshot;
            const ancestor = for (data.nodes) |candidate| {
                if (candidate.id == parent) break candidate;
            } else return error.InvalidSnapshot;
            if (ancestor.kind != .directory) return error.InvalidSnapshot;
            parent = ancestor.parent;
        }
    }
    for (data.receipts, 0..) |receipt, i| {
        if (receipt.request_id == 0 or receipt.result.inode >= data.next_id) return error.InvalidSnapshot;
        for (data.receipts[0..i]) |previous| {
            if (previous.request_id == receipt.request_id) return error.InvalidSnapshot;
        }
    }
}

pub fn publicationStatus(node: Node, publication: Publication, backends: []const Backend) Status {
    if (node.kind != .file) return .not_file;
    if (node.mutable_file != null) return .storage_conflict;
    if (node.current_version != publication.expected_version) return .version_conflict;
    const status = versionStatus(publication.version, backends);
    if (status != .ok) return status;
    if ((node.replicas == .two) != (publication.version.backends[1] != 0)) return .replica_mismatch;
    return .ok;
}

fn versionStatus(version: Version, backends: []const Backend) Status {
    if (version.id == 0 or version.inode <= root_id or version.size > std.math.maxInt(i64) or version.backends[0] == 0) return .invalid_version;
    return replicaStatus(version.backends, backends);
}

fn replicaStatus(ids: [2]u64, backends: []const Backend) Status {
    const first = for (backends) |backend| {
        if (backend.id == ids[0]) break backend;
    } else return .backend_not_found;
    if (ids[1] != 0) {
        const second = for (backends) |backend| {
            if (backend.id == ids[1]) break backend;
        } else return .backend_not_found;
        if (first.failure_domain == second.failure_domain) return .same_failure_domain;
    }
    return .ok;
}

pub fn mutableInode(update: MutableUpdate) u64 {
    return switch (update) {
        inline else => |c| c.inode,
    };
}

fn mutableStatus(file: MutableFile, backends: []const Backend) Status {
    if (file.generation == 0 or file.next_sequence == 0 or file.size > std.math.maxInt(i64)) return .invalid_request;
    if (file.backends[0] == 0 or file.backends[1] == 0) return .replica_mismatch;
    return replicaStatus(file.backends, backends);
}

/// Shared deterministic transition for the in-memory and transactional stores.
/// Data durability and exclusive ownership must be established by the caller.
pub fn updateMutable(node: *Node, update: MutableUpdate, backends: []const Backend) Status {
    if (node.id != mutableInode(update)) return .not_found;
    if (node.kind != .file) return .not_file;
    switch (update) {
        .attach => |c| {
            if (node.mutable_file != null) return .storage_conflict;
            if (node.current_version != c.expected_version) return .version_conflict;
            if (node.replicas != .two) return .replica_mismatch;
            const status = mutableStatus(c.file, backends);
            if (status != .ok) return status;
            node.mutable_file = c.file;
            node.current_version = 0;
        },
        .checkpoint => |c| {
            const file = node.mutable_file orelse return .storage_conflict;
            if (c.generation != file.generation) return .storage_conflict;
            if (c.size > std.math.maxInt(i64) or c.next_sequence == 0) return .invalid_request;
            if (c.expected_sequence != file.next_sequence or c.next_sequence < file.next_sequence) return .sequence_conflict;
            if (c.next_sequence == file.next_sequence and c.size != file.size) return .sequence_conflict;
            node.mutable_file.?.next_sequence = c.next_sequence;
            node.mutable_file.?.size = c.size;
        },
    }
    return .ok;
}
