const std = @import("std");

pub const root_id: u64 = 1;
pub const max_nodes = 4096;
pub const max_receipts = 8192;
pub const Replicas = enum { one, two };
pub const Kind = enum { directory, file };
pub const Node = struct {
    id: u64,
    parent: u64,
    name: []const u8,
    kind: Kind,
    replicas: Replicas,
};
pub const Command = union(enum) {
    create: struct { parent: u64, name: []const u8, kind: Kind, replicas: ?Replicas = null },
    rename: struct { id: u64, parent: u64, name: []const u8 },
    remove: struct { id: u64 },
    set_replicas: struct { id: u64, replicas: Replicas },
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
};
pub const Result = struct { status: Status, inode: u64 = 0 };
pub const Receipt = struct { request_id: u64, digest: [32]u8, result: Result };
pub const Snapshot = struct {
    next_id: u64,
    nodes: []const Node,
    receipts: []const Receipt,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    receipts: std.ArrayList(Receipt) = .empty,
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
                self.nodes.items[i].replicas = c.replicas;
                return .{ .status = .ok, .inode = c.id };
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
        return .{ .next_id = self.next_id, .nodes = self.nodes.items, .receipts = self.receipts.items };
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
    const root = data.nodes[0];
    if (root.id != root_id or root.parent != 0 or root.name.len != 0 or root.kind != .directory) return error.InvalidSnapshot;
    for (data.nodes, 0..) |node, i| {
        if (node.id == 0 or node.id >= data.next_id) return error.InvalidSnapshot;
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
