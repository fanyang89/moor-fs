const std = @import("std");
const raft = @import("raftz");
const grpc = @import("grpc_lite");
const Store = @import("durable.zig").Store;
const protocol = @import("machine.zig");
const metadata = @import("metadata.zig");
const wire = @import("wire.zig");

pub const Config = struct {
    node_id: u64,
    cluster_id: raft.ClusterId,
    raft_listen: []const u8,
    api_listen: []const u8,
    data_dir: []const u8,
    peers: []const raft.Peer,
    snapshot_entries: u64 = 1000,

    pub fn validate(self: Config) !void {
        if (self.node_id == 0 or self.data_dir.len == 0 or self.peers.len != 3 or
            std.mem.allEqual(u8, &self.cluster_id, 0)) return error.InvalidConfig;
        _ = try endpoint(self.api_listen);
        _ = try endpoint(self.raft_listen);
        if (std.mem.eql(u8, self.api_listen, self.raft_listen)) return error.InvalidConfig;
        var local = false;
        for (self.peers, 0..) |peer, i| {
            const address = peer.context orelse return error.InvalidConfig;
            _ = try endpoint(address);
            if (peer.id == 0) return error.InvalidConfig;
            for (self.peers[0..i]) |other| {
                if (other.id == peer.id or std.mem.eql(u8, other.context.?, address)) return error.InvalidConfig;
            }
            if (peer.id == self.node_id) {
                if (!std.mem.eql(u8, address, self.raft_listen)) return error.InvalidConfig;
                local = true;
            }
        }
        if (!local) return error.InvalidConfig;
    }
};

pub fn endpoint(text: []const u8) !struct { host: []const u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidEndpoint;
    const port = try std.fmt.parseUnsigned(u16, text[colon + 1 ..], 10);
    if (port == 0) return error.InvalidEndpoint;
    _ = try std.Io.net.IpAddress.parseIp4(text[0..colon], port);
    return .{ .host = text[0..colon], .port = port };
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    wal_path: []u8,
    store: Store,
    transport: *raft.GrpcLiteTransport,
    node: *raft.Raftor,
    server: grpc.Server,
    driver: std.Thread,
    failed: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    running: bool = false,

    /// Config strings and peers are borrowed until destroy; allocator must be thread-safe.
    pub fn create(allocator: std.mem.Allocator, config: Config) !*Runtime {
        try config.validate();
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.failed = .init(false);
        self.exited = .init(false);
        self.running = false;
        const dir = try allocator.dupeSentinel(u8, config.data_dir, 0);
        defer allocator.free(dir);
        const fs = raft.realFileSystem();
        if (try fs.makeDir(dir)) {
            const parent = try allocator.dupeSentinel(u8, std.fs.path.dirname(dir) orelse ".", 0);
            defer allocator.free(parent);
            try fs.syncDir(parent);
        }
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/metadata", .{dir}, 0);
        defer allocator.free(path);
        _ = try fs.makeDir(path);
        self.store = try Store.open(allocator, path, 256 * 1024 * 1024);
        errdefer self.store.close();
        try self.store.bindIdentity(config.cluster_id, config.node_id);
        try fs.syncDir(path);
        try fs.syncDir(dir);
        const max_message = protocol.max_snapshot_bytes + 1024 * 1024;
        self.transport = try raft.GrpcLiteTransport.create(allocator, .{
            .identity = .{ .cluster_id = config.cluster_id, .node_id = config.node_id },
            .listen_addr = config.raft_listen,
            .stream_limits = .{
                .max_message_size = max_message,
                .max_inbound_buffer_size = max_message + 5,
                .max_outbound_buffer_size = max_message + 5,
            },
            .mailbox_max_bytes = max_message * 2,
        });
        errdefer self.transport.destroy();
        var options: raft.RaftorConfig = .{};
        options.raft.id = config.node_id;
        options.raft.election_tick = 15;
        options.raft.heartbeat_tick = 2;
        options.raft.check_quorum = true;
        options.raft.pre_vote = true;
        options.raft.disable_proposal_forwarding = true;
        options.cluster_id = config.cluster_id;
        options.listen_addr = config.raft_listen;
        options.advertise_addr = config.raft_listen;
        options.initial_peers = config.peers;
        self.wal_path = try std.fmt.allocPrint(allocator, "{s}/raft", .{dir});
        errdefer allocator.free(self.wal_path);
        options.data_dir = self.wal_path;
        options.checksum_enabled = true;
        options.proposal_timeout_ticks = 50;
        options.read_index_timeout_ticks = 50;
        options.snapshot_entries_threshold = config.snapshot_entries;
        self.node = try raft.Raftor.createWithTransport(allocator, options, self.store.stateMachine(), self.transport.transport());
        errdefer self.node.destroy();
        try fs.syncDir(dir);
        const api = try endpoint(config.api_listen);
        self.server = try grpc.Server.init(allocator, .{
            .host = api.host,
            .port = api.port,
            .reactor_count = 2,
            .max_request_size = protocol.max_command_bytes + 8,
        });
        errdefer self.server.deinit();
        try self.server.registerUnary("/nas.fs.Metadata/Apply", grpc.UnaryHandler.bind(Runtime, self, apply));
        try self.server.registerUnary("/nas.fs.Metadata/Get", grpc.UnaryHandler.bind(Runtime, self, get));
        try self.server.registerUnary("/nas.fs.Metadata/Lookup", grpc.UnaryHandler.bind(Runtime, self, lookup));
        try self.server.registerUnary("/nas.fs.Metadata/List", grpc.UnaryHandler.bind(Runtime, self, list));
        try self.server.registerUnary("/nas.fs.Metadata/Backend", grpc.UnaryHandler.bind(Runtime, self, backend));
        try self.server.registerUnary("/nas.fs.Metadata/Version", grpc.UnaryHandler.bind(Runtime, self, version));
        try self.server.registerUnary("/nas.fs.Metadata/Status", grpc.UnaryHandler.bind(Runtime, self, status));
        self.driver = try std.Thread.spawn(.{}, drive, .{self});
        errdefer {
            self.node.stop();
            self.driver.join();
        }
        try self.server.start();
        self.running = true;
        return self;
    }

    pub fn shutdown(self: *Runtime) void {
        if (!self.running) return;
        self.server.shutdownGracefully(2 * std.time.ns_per_s);
        self.node.stop();
        self.server.wait();
        self.driver.join();
        self.running = false;
    }

    pub fn destroy(self: *Runtime) void {
        self.shutdown();
        self.server.deinit();
        self.node.destroy();
        self.allocator.free(self.wal_path);
        self.transport.destroy();
        self.store.close();
        self.allocator.destroy(self);
    }

    fn drive(self: *Runtime) void {
        self.node.run() catch |err| {
            if (err != error.ShuttingDown) {
                self.failed.store(true, .release);
                raft.log.err(@src(), "Raft stopped: {s}", .{@errorName(err)});
            }
            self.node.stop();
        };
        self.exited.store(true, .release);
    }

    fn apply(self: *Runtime, allocator: std.mem.Allocator, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        const data = wire.decode(request) catch return fail(allocator, error.InvalidRequest);
        if (data.len > protocol.max_command_bytes) return fail(allocator, error.InvalidRequest);
        const parsed = std.json.parseFromSlice(metadata.Request, allocator, data, .{}) catch return fail(allocator, error.InvalidRequest);
        defer parsed.deinit();
        if (parsed.value.version != 1 or parsed.value.request_id == 0) return fail(allocator, error.InvalidRequest);
        if (!self.node.isLeader()) return fail(allocator, error.NotLeader);
        var pending: Pending = .{};
        self.node.propose(data, .{ .ctx = &pending, .function = Pending.proposed }) catch |err| return fail(allocator, err);
        pending.wait();
        if (pending.failure) |err| return fail(allocator, err);
        const result = try protocol.decodeResult(&pending.response);
        if (result.status == .ok) switch (parsed.value.command) {
            .publish => |publication| {
                if (publication.version.size != 0) @import("publish_fault.zig").beforeReply(publication.version.inode, parsed.value.request_id);
            },
            else => {},
        };
        return reply(allocator, result);
    }

    fn get(self: *Runtime, allocator: std.mem.Allocator, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        const data = wire.decode(request) catch return fail(allocator, error.InvalidRequest);
        const parsed = std.json.parseFromSlice(struct { id: u64 }, allocator, data, .{}) catch return fail(allocator, error.InvalidRequest);
        defer parsed.deinit();
        self.readBarrier() catch |err| return fail(allocator, err);
        const node = self.store.get(allocator, parsed.value.id) catch |err| return fail(allocator, err);
        defer if (node) |value| allocator.free(value.name);
        return reply(allocator, node);
    }

    fn status(self: *Runtime, allocator: std.mem.Allocator, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        _ = wire.decode(request) catch return fail(allocator, error.InvalidRequest);
        if (self.failed.load(.acquire)) return fail(allocator, error.ShuttingDown);
        return reply(allocator, self.node.getStatus());
    }

    fn readBarrier(self: *Runtime) !void {
        if (!self.node.isLeader()) return error.NotLeader;
        var pending: Pending = .{};
        try self.node.readIndex("metadata-read", .{ .ctx = &pending, .function = Pending.read });
        pending.wait();
        if (pending.failure) |err| return err;
    }

    fn backend(self: *Runtime, allocator: std.mem.Allocator, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        return self.readRecord(allocator, request, true);
    }

    fn version(self: *Runtime, allocator: std.mem.Allocator, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        return self.readRecord(allocator, request, false);
    }

    fn readRecord(self: *Runtime, allocator: std.mem.Allocator, request: []const u8, comptime is_backend: bool) !grpc.UnaryResponse {
        const data = wire.decode(request) catch return fail(allocator, error.InvalidRequest);
        const parsed = std.json.parseFromSlice(struct { id: u64 }, allocator, data, .{}) catch return fail(allocator, error.InvalidRequest);
        defer parsed.deinit();
        self.readBarrier() catch |err| return fail(allocator, err);
        const result = if (is_backend)
            self.store.getBackend(parsed.value.id) catch |err| return fail(allocator, err)
        else
            self.store.getVersion(parsed.value.id) catch |err| return fail(allocator, err);
        return reply(allocator, result);
    }

    fn lookup(self: *Runtime, allocator: std.mem.Allocator, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        const data = wire.decode(request) catch return fail(allocator, error.InvalidRequest);
        const parsed = std.json.parseFromSlice(struct { parent: u64, name: []const u8 }, allocator, data, .{}) catch return fail(allocator, error.InvalidRequest);
        defer parsed.deinit();
        self.readBarrier() catch |err| return fail(allocator, err);
        const node = self.store.lookupNode(allocator, parsed.value.parent, parsed.value.name) catch |err| return fail(allocator, err);
        defer if (node) |value| allocator.free(value.name);
        return reply(allocator, node);
    }

    fn list(self: *Runtime, allocator: std.mem.Allocator, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        const data = wire.decode(request) catch return fail(allocator, error.InvalidRequest);
        const parsed = std.json.parseFromSlice(@import("durable.zig").ListRequest, allocator, data, .{}) catch return fail(allocator, error.InvalidRequest);
        defer parsed.deinit();
        self.readBarrier() catch |err| return fail(allocator, err);
        const page = self.store.list(allocator, parsed.value) catch |err| return fail(allocator, err);
        defer page.deinit(allocator);
        return reply(allocator, page);
    }
};

const Pending = struct {
    done: std.atomic.Value(bool) = .init(false),
    failure: ?raft.Error = null,
    response: [protocol.response_size]u8 = undefined,

    fn proposed(ctx: *anyopaque, result: raft.ProposalResult) void {
        const self: *Pending = @ptrCast(@alignCast(ctx));
        switch (result) {
            .ok => |bytes| {
                if (bytes.len == self.response.len) @memcpy(&self.response, bytes) else self.failure = error.Fatal;
            },
            .err => |err| self.failure = err,
        }
        self.done.store(true, .release);
    }

    fn read(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *Pending = @ptrCast(@alignCast(ctx));
        switch (result) {
            .ok => {},
            .err => |err| self.failure = err,
        }
        self.done.store(true, .release);
    }

    fn wait(self: *Pending) void {
        while (!self.done.load(.acquire)) {
            const duration: std.os.linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&duration, null);
        }
    }
};

fn reply(allocator: std.mem.Allocator, value: anytype) !grpc.UnaryResponse {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const bytes = try wire.encode(allocator, json);
    defer allocator.free(bytes);
    return grpc.UnaryResponse.ok(allocator, bytes);
}

fn fail(allocator: std.mem.Allocator, err: anyerror) !grpc.UnaryResponse {
    const code: grpc.StatusCode = switch (err) {
        error.NotLeader, error.LostLeadership => .failed_precondition,
        error.InvalidRequest => .invalid_argument,
        error.NotFound => .not_found,
        error.NotDirectory => .failed_precondition,
        error.ProposalBackpressure, error.ReadIndexBackpressure => .resource_exhausted,
        error.ShuttingDown, error.Timeout, error.ProposalDropped => .unavailable,
        else => .internal,
    };
    return grpc.UnaryResponse.fail(allocator, .init(code, @errorName(err)));
}

pub fn call(allocator: std.mem.Allocator, address: []const u8, method: []const u8, json: []const u8) ![]u8 {
    var addresses: [3][]const u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, address, ',');
    while (parts.next()) |part| {
        if (count == addresses.len) return error.InvalidEndpoint;
        _ = try endpoint(part);
        addresses[count] = part;
        count += 1;
    }
    if (count == 1) return callOne(allocator, address, method, json);
    if (std.mem.eql(u8, method, "Status")) return error.InvalidEndpoint;
    for (0..5) |round| {
        for (addresses[0..count]) |target| {
            return callOne(allocator, target, method, json) catch |err| switch (err) {
                error.RetryableRpc, error.ConnectionFailed => continue,
                else => return err,
            };
        }
        if (round < 4) {
            const duration: std.os.linux.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.os.linux.nanosleep(&duration, null);
        }
    }
    return error.ClusterUnavailable;
}

fn callOne(allocator: std.mem.Allocator, address: []const u8, method: []const u8, json: []const u8) ![]u8 {
    _ = try endpoint(address);
    var channel = try grpc.Channel.init(allocator, address, .{});
    defer channel.deinit();
    const path = try std.fmt.allocPrint(allocator, "/nas.fs.Metadata/{s}", .{method});
    defer allocator.free(path);
    const request = try wire.encode(allocator, json);
    defer allocator.free(request);
    var result = try channel.callUnary(allocator, path, request, .{ .timeout_ns = 8 * std.time.ns_per_s, .max_response_size = 32776 });
    defer result.deinit();
    if (!result.status.isOk()) {
        if (result.status.code == .unavailable or result.status.code == .deadline_exceeded or
            result.status.code == .resource_exhausted or
            (result.status.code == .failed_precondition and
                (std.mem.eql(u8, result.status.message, "NotLeader") or std.mem.eql(u8, result.status.message, "LostLeadership")))) return error.RetryableRpc;
        std.log.err("RPC {s}: {s}", .{ @tagName(result.status.code), result.status.message });
        if (result.status.code == .not_found) return error.NotFound;
        if (result.status.code == .failed_precondition and std.mem.eql(u8, result.status.message, "NotDirectory")) return error.NotDirectory;
        return error.RpcFailed;
    }
    return allocator.dupe(u8, try wire.decode(result.payload));
}
