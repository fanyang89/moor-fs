const std = @import("std");
const raft = @import("raftz");
const lmdb = @import("lmdb.zig");
const m = @import("metadata.zig");
const protocol = @import("machine.zig");

const Meta = struct { schema: u32 = 3, index: u64 = 0, term: u64 = 0, next_id: u64 = 2 };

pub const ListRequest = struct { parent: u64, after: ?[]const u8 = null, limit: u8 = 16 };
pub const Page = struct {
    entries: []m.Node,
    next: ?[]const u8,

    pub fn deinit(self: Page, allocator: std.mem.Allocator) void {
        for (self.entries) |node| allocator.free(node.name);
        allocator.free(self.entries);
        if (self.next) |name| allocator.free(name);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    env: lmdb.Environment,
    meta_db: lmdb.c.MDB_dbi,
    nodes_db: lmdb.c.MDB_dbi,
    dirents_db: lmdb.c.MDB_dbi,
    requests_db: lmdb.c.MDB_dbi,
    backends_db: lmdb.c.MDB_dbi,
    versions_db: lmdb.c.MDB_dbi,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8, map_size: usize) !Store {
        var env = try lmdb.Environment.open(path, map_size);
        errdefer env.close();
        var txn = try env.begin(false);
        defer txn.abort();
        var self: Store = .{
            .allocator = allocator,
            .env = env,
            .meta_db = try txn.openDatabase("meta"),
            .nodes_db = try txn.openDatabase("inodes"),
            .dirents_db = try txn.openDatabase("dirents"),
            .requests_db = try txn.openDatabase("requests"),
            .backends_db = try txn.openDatabase("backends"),
            .versions_db = try txn.openDatabase("versions"),
        };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (try txn.get(self.meta_db, "state")) |_| {
            var meta = try self.readMeta(&txn, arena.allocator());
            if (meta.schema == 1) {
                if (try txn.count(self.backends_db) != 0 or try txn.count(self.versions_db) != 0) return error.CorruptStore;
                meta.schema = 2;
            }
            if (meta.schema == 2) {
                meta.schema = 3;
                try putJson(&txn, self.meta_db, "state", arena.allocator(), meta);
            }
            const root = (try self.readNode(&txn, arena.allocator(), m.root_id)) orelse return error.CorruptStore;
            if (root.parent != 0 or root.name.len != 0 or root.kind != .directory) return error.CorruptStore;
        } else {
            for ([_]lmdb.c.MDB_dbi{ self.meta_db, self.nodes_db, self.dirents_db, self.requests_db, self.backends_db, self.versions_db }) |db| {
                if (try txn.count(db) != 0) return error.CorruptStore;
            }
            try self.putNode(&txn, arena.allocator(), .{ .id = 1, .parent = 0, .name = "", .kind = .directory, .replicas = .two });
            try putJson(&txn, self.meta_db, "state", arena.allocator(), Meta{});
        }
        try txn.commit();
        return self;
    }

    pub fn close(self: *Store) void {
        self.env.close();
        self.* = undefined;
    }

    pub fn stateMachine(self: *Store) raft.StateMachine {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn bindIdentity(self: *Store, cluster_id: raft.ClusterId, node_id: u64) !void {
        const Identity = struct { cluster_id: raft.ClusterId, node_id: u64 };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var txn = try self.env.begin(false);
        defer txn.abort();
        if (try txn.get(self.meta_db, "identity")) |data| {
            const identity = try parse(Identity, arena.allocator(), data);
            if (identity.node_id != node_id or !std.mem.eql(u8, &identity.cluster_id, &cluster_id)) return error.IdentityMismatch;
        } else {
            const meta = try self.readMeta(&txn, arena.allocator());
            if (meta.index != 0) return error.UnboundMetadata;
            try putJson(&txn, self.meta_db, "identity", arena.allocator(), Identity{ .cluster_id = cluster_id, .node_id = node_id });
        }
        try txn.commit();
    }

    pub fn requireStandalone(self: *Store) !void {
        var txn = try self.env.begin(true);
        defer txn.abort();
        if (try txn.get(self.meta_db, "identity") != null) return error.ClusterManagedStore;
    }

    pub fn applied(self: *Store) !raft.DurableApplied {
        var txn = try self.env.begin(true);
        defer txn.abort();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const meta = try self.readMeta(&txn, arena.allocator());
        return .{ .index = meta.index, .term = meta.term };
    }

    /// The caller owns the returned node's name and must free it with allocator.
    pub fn get(self: *Store, allocator: std.mem.Allocator, id: u64) !?m.Node {
        var txn = try self.env.begin(true);
        defer txn.abort();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var node = (try self.readNode(&txn, arena.allocator(), id)) orelse return null;
        node.name = try allocator.dupe(u8, node.name);
        return node;
    }

    pub fn lookup(self: *Store, parent: u64, name: []const u8) !?u64 {
        if (!m.validName(name)) return null;
        var txn = try self.env.begin(true);
        defer txn.abort();
        return self.find(&txn, parent, name);
    }

    pub fn getBackend(self: *Store, id: u64) !?m.Backend {
        return self.record(m.Backend, self.backends_db, id);
    }

    pub fn getVersion(self: *Store, id: u64) !?m.Version {
        return self.record(m.Version, self.versions_db, id);
    }

    fn record(self: *Store, comptime T: type, db: lmdb.c.MDB_dbi, id: u64) !?T {
        var txn = try self.env.begin(true);
        defer txn.abort();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const key = idKey(id);
        const data = (try txn.get(db, &key)) orelse return null;
        const result = try parse(T, arena.allocator(), data);
        if (result.id != id) return error.CorruptStore;
        return result;
    }

    fn requireDirectory(self: *Store, txn: *lmdb.Transaction, allocator: std.mem.Allocator, id: u64) !void {
        const node = (try self.readNode(txn, allocator, id)) orelse return error.NotFound;
        if (node.kind != .directory) return error.NotDirectory;
    }

    pub fn lookupNode(self: *Store, allocator: std.mem.Allocator, parent: u64, name: []const u8) !?m.Node {
        if (!m.validName(name)) return error.InvalidRequest;
        var txn = try self.env.begin(true);
        defer txn.abort();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try self.requireDirectory(&txn, arena.allocator(), parent);
        const id = (try self.find(&txn, parent, name)) orelse return null;
        var node = (try self.readNode(&txn, arena.allocator(), id)) orelse return error.CorruptStore;
        node.name = try allocator.dupe(u8, node.name);
        return node;
    }

    pub fn list(self: *Store, allocator: std.mem.Allocator, request: ListRequest) !Page {
        if (request.limit == 0 or request.limit > 16) return error.InvalidRequest;
        if (request.after) |name| if (!m.validName(name)) return error.InvalidRequest;
        var txn = try self.env.begin(true);
        defer txn.abort();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try self.requireDirectory(&txn, arena.allocator(), request.parent);
        var entries: std.ArrayList(m.Node) = .empty;
        errdefer {
            for (entries.items) |node| allocator.free(node.name);
            entries.deinit(allocator);
        }
        var cursor: ?*lmdb.c.MDB_cursor = null;
        try lmdb.check(lmdb.c.mdb_cursor_open(txn.handle, self.dirents_db, &cursor));
        defer lmdb.c.mdb_cursor_close(cursor);
        var buffer: [263]u8 = undefined;
        const start = directoryKey(&buffer, request.parent, request.after orelse "");
        var key = lmdb.value(start);
        var value: lmdb.c.MDB_val = undefined;
        var rc = lmdb.c.mdb_cursor_get(cursor, &key, &value, lmdb.c.MDB_SET_RANGE);
        var next: ?[]const u8 = null;
        errdefer if (next) |name| allocator.free(name);
        while (rc != lmdb.c.MDB_NOTFOUND) : (rc = lmdb.c.mdb_cursor_get(cursor, &key, &value, lmdb.c.MDB_NEXT)) {
            try lmdb.check(rc);
            const bytes = lmdb.bytes(key);
            if (!std.mem.startsWith(u8, bytes, start[0..8])) break;
            if (request.after != null and std.mem.eql(u8, bytes, start)) continue;
            if (entries.items.len == request.limit) {
                next = try allocator.dupe(u8, entries.items[entries.items.len - 1].name);
                break;
            }
            const data = lmdb.bytes(value);
            if (data.len != 8) return error.CorruptStore;
            var node = (try self.readNode(&txn, arena.allocator(), std.mem.readInt(u64, data[0..8], .big))) orelse return error.CorruptStore;
            node.name = try allocator.dupe(u8, node.name);
            entries.append(allocator, node) catch |err| {
                allocator.free(node.name);
                return err;
            };
        }
        return .{ .entries = try entries.toOwnedSlice(allocator), .next = next };
    }

    pub fn applyEntry(self: *Store, entry: raft.Entry) !raft.ApplyResult {
        if (entry.entry_type != .normal or entry.term == 0) return error.EntryParseError;
        if (entry.data.len > protocol.max_command_bytes) return error.MessageTooLarge;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const request: ?m.Request = if (entry.data.len == 0) null else parse(m.Request, allocator, entry.data) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.EntryParseError,
        };
        const response = if (request != null) try self.allocator.alloc(u8, protocol.response_size) else null;
        errdefer if (response) |data| self.allocator.free(data);
        var txn = try self.env.begin(false);
        defer txn.abort();
        var meta = try self.readMeta(&txn, allocator);
        if (entry.index <= meta.index or entry.term < meta.term) return error.EntryParseError;
        if (request) |r| {
            const result = try self.applyRequest(&txn, allocator, &meta, r);
            response.?[0] = 1;
            response.?[1] = @backingInt(result.status);
            std.mem.writeInt(u64, response.?[2..10], result.inode, .little);
        }
        meta.index = entry.index;
        meta.term = entry.term;
        try putJson(&txn, self.meta_db, "state", allocator, meta);
        try txn.commit();
        return .{ .response = response };
    }

    fn applyRequest(self: *Store, txn: *lmdb.Transaction, allocator: std.mem.Allocator, meta: *Meta, request: m.Request) !m.Result {
        if (request.version != 1) return .{ .status = .unsupported_version };
        if (request.request_id == 0) return .{ .status = .invalid_request };
        const digest = try m.requestDigest(allocator, request);
        const key = idKey(request.request_id);
        if (try txn.get(self.requests_db, &key)) |data| {
            const receipt = try parse(m.Receipt, allocator, data);
            if (receipt.request_id != request.request_id) return error.CorruptStore;
            if (!std.mem.eql(u8, &digest, &receipt.digest)) return .{ .status = .request_conflict };
            return receipt.result;
        }
        if (try txn.count(self.requests_db) >= m.max_receipts) return .{ .status = .capacity_exceeded };
        const result = try self.execute(txn, allocator, meta, request.command);
        try putJson(txn, self.requests_db, &key, allocator, m.Receipt{
            .request_id = request.request_id,
            .digest = digest,
            .result = result,
        });
        return result;
    }

    fn execute(self: *Store, txn: *lmdb.Transaction, allocator: std.mem.Allocator, meta: *Meta, command: m.Command) !m.Result {
        switch (command) {
            .remove_entry => |r| {
                if (!m.validName(r.name)) return .{ .status = .invalid_name };
                const id = (try self.find(txn, r.parent, r.name)) orelse return .{ .status = .not_found };
                const node = (try self.readNode(txn, allocator, id)) orelse return error.CorruptStore;
                if (node.kind != r.kind) return .{ .status = if (r.kind == .file) .not_file else .not_directory };
                return self.execute(txn, allocator, meta, .{ .remove = .{ .id = id } });
            },
            .rename_entry => |r| {
                if (!m.validName(r.name)) return .{ .status = .invalid_name };
                const id = (try self.find(txn, r.parent, r.name)) orelse return .{ .status = .not_found };
                return self.execute(txn, allocator, meta, .{ .rename = .{ .id = id, .parent = r.new_parent, .name = r.new_name } });
            },
            .create => |r| {
                if (!m.validName(r.name)) return .{ .status = .invalid_name };
                const parent = (try self.readNode(txn, allocator, r.parent)) orelse return .{ .status = .not_found };
                if (parent.kind != .directory) return .{ .status = .not_directory };
                if (try self.find(txn, r.parent, r.name) != null) return .{ .status = .already_exists };
                if (try txn.count(self.nodes_db) >= m.max_nodes or meta.next_id == std.math.maxInt(u64)) return .{ .status = .capacity_exceeded };
                const id = meta.next_id;
                try self.putNode(txn, allocator, .{
                    .id = id,
                    .parent = r.parent,
                    .name = r.name,
                    .kind = r.kind,
                    .replicas = r.replicas orelse parent.replicas,
                });
                meta.next_id += 1;
                return .{ .status = .ok, .inode = id };
            },
            .rename => |r| {
                if (r.id == m.root_id) return .{ .status = .root_protected };
                if (!m.validName(r.name)) return .{ .status = .invalid_name };
                var node = (try self.readNode(txn, allocator, r.id)) orelse return .{ .status = .not_found };
                const parent = (try self.readNode(txn, allocator, r.parent)) orelse return .{ .status = .not_found };
                if (parent.kind != .directory) return .{ .status = .not_directory };
                if (try self.find(txn, r.parent, r.name)) |target| {
                    if (target != r.id) return .{ .status = .already_exists };
                }
                var ancestor = parent.id;
                var depth: usize = 0;
                while (ancestor != 0) : (depth += 1) {
                    if (ancestor == r.id) return .{ .status = .cycle };
                    if (depth >= m.max_nodes) return error.CorruptStore;
                    ancestor = ((try self.readNode(txn, allocator, ancestor)) orelse return error.CorruptStore).parent;
                }
                var key: [263]u8 = undefined;
                try txn.delete(self.dirents_db, directoryKey(&key, node.parent, node.name));
                node.parent = r.parent;
                node.name = r.name;
                try self.putNode(txn, allocator, node);
                return .{ .status = .ok, .inode = r.id };
            },
            .remove => |r| {
                if (r.id == m.root_id) return .{ .status = .root_protected };
                const node = (try self.readNode(txn, allocator, r.id)) orelse return .{ .status = .not_found };
                const id = idKey(r.id);
                if (try txn.hasPrefix(self.dirents_db, &id)) return .{ .status = .not_empty };
                var key: [263]u8 = undefined;
                try txn.delete(self.dirents_db, directoryKey(&key, node.parent, node.name));
                try txn.delete(self.nodes_db, &id);
                return .{ .status = .ok, .inode = r.id };
            },
            .set_replicas => |r| {
                var node = (try self.readNode(txn, allocator, r.id)) orelse return .{ .status = .not_found };
                if (node.mutable_file != null and r.replicas != .two) return .{ .status = .replica_mismatch };
                node.replicas = r.replicas;
                try self.putNode(txn, allocator, node);
                return .{ .status = .ok, .inode = r.id };
            },
            .register_backend => |backend| {
                if (backend.id == 0 or backend.failure_domain == 0) return .{ .status = .invalid_request };
                const key = idKey(backend.id);
                if (try txn.get(self.backends_db, &key) != null) return .{ .status = .already_exists };
                if (try txn.count(self.backends_db) == m.max_backends) return .{ .status = .capacity_exceeded };
                try putJson(txn, self.backends_db, &key, allocator, backend);
                return .{ .status = .ok };
            },
            .publish => |publication| {
                const v = publication.version;
                var node = (try self.readNode(txn, allocator, v.inode)) orelse return .{ .status = .not_found };
                var backends: [2]m.Backend = undefined;
                var count: usize = 0;
                for (v.backends) |id| {
                    const key = idKey(id);
                    if (try txn.get(self.backends_db, &key)) |data| {
                        backends[count] = try parse(m.Backend, allocator, data);
                        count += 1;
                    }
                }
                const status = m.publicationStatus(node, publication, backends[0..count]);
                if (status != .ok) return .{ .status = status };
                const key = idKey(v.id);
                if (try txn.get(self.versions_db, &key) != null) return .{ .status = .version_conflict };
                if (try txn.count(self.versions_db) == m.max_versions) return .{ .status = .capacity_exceeded };
                try putJson(txn, self.versions_db, &key, allocator, v);
                node.current_version = v.id;
                try self.putNode(txn, allocator, node);
                return .{ .status = .ok, .inode = v.inode };
            },
            .mutable_file => |update| {
                const id = m.mutableInode(update);
                var node = (try self.readNode(txn, allocator, id)) orelse return .{ .status = .not_found };
                var backends: [2]m.Backend = undefined;
                var count: usize = 0;
                if (update == .attach) for (update.attach.file.backends) |backend_id| {
                    const key = idKey(backend_id);
                    if (try txn.get(self.backends_db, &key)) |data| {
                        backends[count] = try parse(m.Backend, allocator, data);
                        count += 1;
                    }
                };
                const status = m.updateMutable(&node, update, backends[0..count]);
                if (status != .ok) return .{ .status = status };
                try self.putNode(txn, allocator, node);
                return .{ .status = .ok, .inode = id };
            },
        }
    }

    fn readMeta(self: *Store, txn: *lmdb.Transaction, allocator: std.mem.Allocator) !Meta {
        const data = (try txn.get(self.meta_db, "state")) orelse return error.CorruptStore;
        const meta = try parse(Meta, allocator, data);
        if (meta.schema < 1 or meta.schema > 3) return error.UnsupportedSchema;
        if (meta.next_id < 2 or (meta.index == 0) != (meta.term == 0)) return error.CorruptStore;
        return meta;
    }

    fn readNode(self: *Store, txn: *lmdb.Transaction, allocator: std.mem.Allocator, id: u64) !?m.Node {
        const key = idKey(id);
        const data = (try txn.get(self.nodes_db, &key)) orelse return null;
        const result = try parse(m.Node, allocator, data);
        if (result.id != id or (id != m.root_id and !m.validName(result.name))) return error.CorruptStore;
        return result;
    }

    fn find(self: *Store, txn: *lmdb.Transaction, parent: u64, name: []const u8) !?u64 {
        var key: [263]u8 = undefined;
        const data = (try txn.get(self.dirents_db, directoryKey(&key, parent, name))) orelse return null;
        if (data.len != 8) return error.CorruptStore;
        return std.mem.readInt(u64, data[0..8], .big);
    }

    fn putNode(self: *Store, txn: *lmdb.Transaction, allocator: std.mem.Allocator, n: m.Node) !void {
        const id = idKey(n.id);
        try putJson(txn, self.nodes_db, &id, allocator, n);
        if (n.id != m.root_id) {
            var key: [263]u8 = undefined;
            try txn.put(self.dirents_db, directoryKey(&key, n.parent, n.name), &id);
        }
    }

    pub fn snapshot(self: *Store, allocator: std.mem.Allocator, index: u64, term: u64) ![]u8 {
        var txn = try self.env.begin(true);
        defer txn.abort();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        const meta = try self.readMeta(&txn, temp);
        if (index < meta.index or term < meta.term or (index == 0) != (term == 0)) return error.SnapshotOutOfDate;
        const state: m.Snapshot = .{
            .next_id = meta.next_id,
            .nodes = try readRecords(m.Node, &txn, self.nodes_db, temp, m.max_nodes),
            .receipts = try readRecords(m.Receipt, &txn, self.requests_db, temp, m.max_receipts),
            .backends = try readRecords(m.Backend, &txn, self.backends_db, temp, m.max_backends),
            .versions = try readRecords(m.Version, &txn, self.versions_db, temp, m.max_versions),
        };
        try m.validateSnapshot(state);
        const data = try std.json.Stringify.valueAlloc(allocator, protocol.Image{ .index = index, .term = term, .state = state }, .{});
        errdefer allocator.free(data);
        if (data.len > protocol.max_snapshot_bytes) return error.MessageTooLarge;
        return data;
    }

    pub fn restore(self: *Store, index: u64, term: u64, data: []const u8) !void {
        if (data.len > protocol.max_snapshot_bytes) return error.MessageTooLarge;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const image = try parse(protocol.Image, allocator, data);
        if ((image.version < 1 or image.version > 3) or image.index != index or image.term != term or (index == 0) != (term == 0)) return error.InvalidSnapshot;
        try m.validateSnapshot(image.state);
        var txn = try self.env.begin(false);
        defer txn.abort();
        const previous = try self.readMeta(&txn, allocator);
        if (index < previous.index or term < previous.term) return error.SnapshotOutOfDate;
        try txn.clear(self.nodes_db);
        try txn.clear(self.dirents_db);
        try txn.clear(self.requests_db);
        try txn.clear(self.backends_db);
        try txn.clear(self.versions_db);
        for (image.state.nodes) |n| try self.putNode(&txn, allocator, n);
        for (image.state.receipts) |r| {
            const key = idKey(r.request_id);
            try putJson(&txn, self.requests_db, &key, allocator, r);
        }
        for (image.state.backends) |b| {
            const key = idKey(b.id);
            try putJson(&txn, self.backends_db, &key, allocator, b);
        }
        for (image.state.versions) |v| {
            const key = idKey(v.id);
            try putJson(&txn, self.versions_db, &key, allocator, v);
        }
        try putJson(&txn, self.meta_db, "state", allocator, Meta{ .index = index, .term = term, .next_id = image.state.next_id });
        try txn.commit();
    }

    fn applyImpl(ctx: *anyopaque, entry: raft.Entry) raft.Error!raft.ApplyResult {
        const self: *Store = @ptrCast(@alignCast(ctx));
        return self.applyEntry(entry) catch |err| return mapError(err);
    }

    fn appliedImpl(ctx: *anyopaque) raft.Error!raft.DurableApplied {
        const self: *Store = @ptrCast(@alignCast(ctx));
        return self.applied() catch |err| return mapError(err);
    }

    fn snapshotImpl(ctx: *anyopaque, allocator: std.mem.Allocator, index: u64, term: u64, conf: raft.ConfState) raft.Error!raft.Snapshot {
        const self: *Store = @ptrCast(@alignCast(ctx));
        const data = self.snapshot(allocator, index, term) catch |err| return mapError(err);
        errdefer allocator.free(data);
        return .{ .data = data, .metadata = .{ .index = index, .term = term, .conf_state = try raft.cloneConfState(allocator, conf) } };
    }

    fn restoreImpl(ctx: *anyopaque, info: raft.SnapshotMetadata, reader: raft.SnapshotReader) raft.Error!void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = try reader.read(&buffer);
            if (count == 0) break;
            if (count > buffer.len or count > protocol.max_snapshot_bytes - data.items.len) return error.MessageTooLarge;
            try data.appendSlice(self.allocator, buffer[0..count]);
        }
        self.restore(info.index, info.term, data.items) catch |err| return mapError(err);
    }

    const vtable: raft.StateMachine.VTable = .{
        .apply = applyImpl,
        .take_snapshot = snapshotImpl,
        .restore_snapshot = restoreImpl,
        .durable_applied = appliedImpl,
    };
};

fn parse(comptime T: type, allocator: std.mem.Allocator, data: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, data, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptStore,
    };
}

fn putJson(txn: *lmdb.Transaction, db: lmdb.c.MDB_dbi, key: []const u8, allocator: std.mem.Allocator, data: anytype) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, data, .{});
    defer allocator.free(encoded);
    try txn.put(db, key, encoded);
}

fn idKey(id: u64) [8]u8 {
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, id, .big);
    return key;
}

fn directoryKey(buffer: *[263]u8, parent: u64, name: []const u8) []const u8 {
    std.debug.assert(name.len <= 255);
    std.mem.writeInt(u64, buffer[0..8], parent, .big);
    for (name, 0..) |byte, i| buffer[8 + i] = std.ascii.toLower(byte);
    return buffer[0 .. 8 + name.len];
}

fn readRecords(comptime T: type, txn: *lmdb.Transaction, db: lmdb.c.MDB_dbi, allocator: std.mem.Allocator, limit: usize) ![]T {
    var cursor: ?*lmdb.c.MDB_cursor = null;
    try lmdb.check(lmdb.c.mdb_cursor_open(txn.handle, db, &cursor));
    defer lmdb.c.mdb_cursor_close(cursor);
    var result: std.ArrayList(T) = .empty;
    var k: lmdb.c.MDB_val = undefined;
    var v: lmdb.c.MDB_val = undefined;
    while (true) {
        const rc = lmdb.c.mdb_cursor_get(cursor, &k, &v, lmdb.c.MDB_NEXT);
        if (rc == lmdb.c.MDB_NOTFOUND) break;
        try lmdb.check(rc);
        if (result.items.len == limit) return error.CorruptStore;
        const record = try parse(T, allocator, lmdb.bytes(v));
        const expected = idKey(if (T == m.Receipt) record.request_id else record.id);
        if (!std.mem.eql(u8, &expected, lmdb.bytes(k))) return error.CorruptStore;
        try result.append(allocator, record);
    }
    return result.toOwnedSlice(allocator);
}

fn mapError(err: anyerror) raft.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EntryParseError => error.EntryParseError,
        error.MessageTooLarge => error.MessageTooLarge,
        error.SnapshotOutOfDate => error.SnapshotOutOfDate,
        else => error.Fatal,
    };
}
