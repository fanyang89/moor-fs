const std = @import("std");
const nas = @import("nas_fs");
const zli = @import("zli");

var stopping = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    var input_buffer: [1024]u8 = undefined;
    var input = std.Io.File.Reader.init(.stdin(), init.io, &input_buffer);
    const options: zli.InitOptions = .{ .allocator = init.gpa, .io = init.io, .writer = &output.interface, .reader = &input.interface };
    const root = try zli.Command.init(options, .{ .name = "nas-fs", .description = "Distributed NAS metadata service", .version = .{ .major = 0, .minor = 1, .patch = 0 } }, help);
    defer root.deinit();
    try register(root, options, "version", "Show version", &.{}, version);
    try register(root, options, "serve-files", "Run the local shared WAL file service", &.{ "endpoint", "config", "runtime-directory", "first-backend", "second-backend" }, @import("service_cli.zig").serve);
    try register(root, options, "metadata-demo", "Run the in-memory demonstration", &.{}, demo);
    try register(root, options, "metadata-show", "Inspect an offline LMDB store", &.{"directory"}, localShow);
    try register(root, options, "metadata-apply", "Apply to an offline test store", &.{ "directory", "index", "term", "json" }, localApply);
    try register(root, options, "apply", "Propose a metadata request to the leader", &.{ "endpoint", "json" }, remoteApply);
    try register(root, options, "get", "Read an inode through the leader with ReadIndex", &.{ "endpoint", "id" }, remoteGet);
    try register(root, options, "status", "Inspect a node's local Raft status", &.{"endpoint"}, remoteStatus);
    try register(root, options, "receipts", "Read the current receipt epoch and capacity", &.{"endpoint"}, remoteReceipts);
    try register(root, options, "rotate-receipts", "Retire all receipts in an expected epoch; old requests will be rejected", &.{ "endpoint", "expected-epoch" }, rotateReceipts);
    try register(root, options, "lookup", "Look up a child by name", &.{ "endpoint", "parent", "name" }, remoteLookup);
    try register(root, options, "list", "List a directory page", &.{ "endpoint", "parent" }, remoteList);
    try register(root, options, "backend", "Read a registered NAS failure domain", &.{ "endpoint", "id" }, remoteBackend);
    try register(root, options, "init-backend", "Initialize a registered backend's guarded object directories", &.{ "endpoint", "config", "id" }, @import("data_cli.zig").initialize);
    try register(root, options, "file-version", "Read an immutable file version", &.{ "endpoint", "id" }, remoteVersion);
    try register(root, options, "put-file", "Copy, verify and publish a file version", &.{ "endpoint", "config", "json", "source" }, @import("data_cli.zig").put);
    try register(root, options, "get-file", "Read a verified replica into a new local file", &.{ "endpoint", "config", "id", "destination" }, @import("data_cli.zig").get);
    try register(root, options, "check-file", "Verify every declared replica of the current file version", &.{ "endpoint", "config", "id" }, @import("data_cli.zig").check);
    try register(root, options, "scrub-mutable", "Recover an existing mutable file and compare both complete replicas", &.{ "endpoint", "config", "id" }, scrubMutable);
    try register(root, options, "seal-mutable", "Persist an idle mutable file's verified content baseline", &.{ "endpoint", "config", "id" }, sealMutable);
    try register(root, options, "repair-mutable", "Restore sealed mutable data, a missing empty active WAL or a missing seal", &.{ "endpoint", "config", "id" }, repairMutable);
    try register(root, options, "repair-file", "Restore a declared replica from a verified copy", &.{ "endpoint", "config", "id", "backend" }, @import("data_cli.zig").repair);
    if (@import("build_options").fuse) try register(root, options, "mount", "Mount the namespace with optional verified reads and dual-replica writes", &.{ "endpoint", "mountpoint" }, mount);
    const serve = try zli.Command.init(options, .{ .name = "serve", .description = "Run a persistent node in a fixed three-voter cluster" }, serveNode);
    try root.addCommand(serve);
    for ([_][]const u8{ "node-id", "cluster-id", "raft-listen", "api-listen", "data-dir", "peers" }) |name| {
        try serve.addFlag(.{ .name = name, .description = name, .type = .String, .default_value = .{ .String = "" } });
    }
    try serve.addFlag(.{ .name = "snapshot-entries", .description = "Applied entries per automatic snapshot (0 disables)", .type = .String, .default_value = .{ .String = "1000" } });
    var args = init.minimal.args.iterate();
    const code = root.run(&args, .{});
    try output.interface.flush();
    if (code != 0) std.process.exit(code);
}

fn register(root: *zli.Command, options: zli.InitOptions, name: []const u8, description: []const u8, args: []const []const u8, handler: *const fn (zli.CommandContext) anyerror!void) !void {
    const command = try zli.Command.init(options, .{ .name = name, .description = description }, handler);
    try root.addCommand(command);
    for (args) |arg| try command.addPositionalArg(.{ .name = arg, .description = arg, .required = true });
    if (std.mem.eql(u8, name, "list")) {
        try command.addFlag(.{ .name = "after", .description = "Exclusive name cursor from previous page", .type = .String, .default_value = .{ .String = "" } });
        try command.addFlag(.{ .name = "limit", .description = "Page size (1-16)", .type = .Int, .default_value = .{ .Int = 16 } });
    }
    if (std.mem.eql(u8, name, "mount")) {
        try command.addFlag(.{ .name = "backends", .description = "Backend mapping JSON for verified file reads", .type = .String, .default_value = .{ .String = "" } });
        try command.addFlag(.{ .name = "write-backends", .description = "Enable writes using two backend IDs, e.g. 1,2", .type = .String, .default_value = .{ .String = "" } });
        try command.addFlag(.{ .name = "write-mode", .description = "Write protocol: staging (default) or opt-in wal", .type = .String, .default_value = .{ .String = "staging" } });
    }
    if (std.mem.eql(u8, name, "repair-file")) {
        try command.addFlag(.{ .name = "replace-corrupt", .description = "Atomically replace a checksum-invalid replica after verified copying", .type = .Bool, .default_value = .{ .Bool = false } });
    }
}

fn help(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

fn version(ctx: zli.CommandContext) !void {
    try ctx.root.printVersion();
}

fn openLocal(ctx: zli.CommandContext) !nas.Store {
    const path = try ctx.allocator.dupeSentinel(u8, ctx.getArg("directory").?, 0);
    defer ctx.allocator.free(path);
    return nas.Store.open(ctx.allocator, path, 256 * 1024 * 1024);
}

fn localShow(ctx: zli.CommandContext) !void {
    var store = try openLocal(ctx);
    defer store.close();
    const cursor = try store.applied();
    const data = try store.snapshot(ctx.allocator, cursor.index, cursor.term);
    defer ctx.allocator.free(data);
    try ctx.writer.print("{s}\n", .{data});
}

fn localApply(ctx: zli.CommandContext) !void {
    var store = try openLocal(ctx);
    defer store.close();
    try store.requireStandalone();
    var result = try store.applyEntry(.{
        .index = try std.fmt.parseUnsigned(u64, ctx.getArg("index").?, 10),
        .term = try std.fmt.parseUnsigned(u64, ctx.getArg("term").?, 10),
        .data = @constCast(ctx.getArg("json").?),
    });
    defer result.deinit(ctx.allocator);
    if (result.response) |response| {
        const decoded = try nas.machine.decodeResult(response);
        try ctx.writer.print("status={s} inode={d}\n", .{ @tagName(decoded.status), decoded.inode });
    }
}

fn remote(ctx: zli.CommandContext, method: []const u8, request: []const u8) !void {
    const data = try nas.runtime.call(ctx.allocator, ctx.getArg("endpoint").?, method, request);
    defer ctx.allocator.free(data);
    try ctx.writer.print("{s}\n", .{data});
}

fn remoteApply(ctx: zli.CommandContext) !void {
    try remote(ctx, "Apply", ctx.getArg("json").?);
}

fn remoteReceipts(ctx: zli.CommandContext) !void {
    try remote(ctx, "Receipts", "{}");
}

fn rotateReceipts(ctx: zli.CommandContext) !void {
    const request: nas.metadata.Request = .{ .request_id = 0, .command = .{ .rotate_receipts = .{ .expected_epoch = try std.fmt.parseUnsigned(u64, ctx.getArg("expected-epoch").?, 10) } } };
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, request, .{});
    defer ctx.allocator.free(json);
    try remote(ctx, "Apply", json);
}

fn remoteGet(ctx: zli.CommandContext) !void {
    try remoteId(ctx, "Get");
}

fn remoteBackend(ctx: zli.CommandContext) !void {
    try remoteId(ctx, "Backend");
}

fn remoteVersion(ctx: zli.CommandContext) !void {
    try remoteId(ctx, "Version");
}

fn remoteId(ctx: zli.CommandContext, method: []const u8) !void {
    const id = try std.fmt.parseUnsigned(u64, ctx.getArg("id").?, 10);
    const data = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .id = id }, .{});
    defer ctx.allocator.free(data);
    try remote(ctx, method, data);
}

fn remoteStatus(ctx: zli.CommandContext) !void {
    try remote(ctx, "Status", "{}");
}

fn mount(ctx: zli.CommandContext) !void {
    try @import("fuse.zig").mount(ctx.allocator, ctx.io, ctx.getArg("endpoint").?, ctx.getArg("mountpoint").?, ctx.flag("backends", []const u8), ctx.flag("write-backends", []const u8), ctx.flag("write-mode", []const u8));
}

fn scrubMutable(ctx: zli.CommandContext) !void {
    try maintainMutable(ctx, false, false);
}

fn sealMutable(ctx: zli.CommandContext) !void {
    try maintainMutable(ctx, true, false);
}

fn repairMutable(ctx: zli.CommandContext) !void {
    try maintainMutable(ctx, false, true);
}

fn maintainMutable(ctx: zli.CommandContext, seal: bool, repair: bool) !void {
    const mappings = try nas.objects.loadMappings(ctx.allocator, ctx.io, ctx.getArg("config").?);
    defer mappings.deinit();
    var client: nas.mutable_rpc.Client = .{ .allocator = ctx.allocator, .endpoints = ctx.getArg("endpoint").? };
    const inode = try std.fmt.parseUnsigned(u64, ctx.getArg("id").?, 10);
    // No migration pair: this maintenance command only accepts existing bindings.
    var access = try nas.mutable_access.Access.openMode(ctx.allocator, ctx.io, client.api(), mappings.value, inode, .{ 0, 0 }, repair);
    defer access.close();
    if (seal) try access.seal();
    const result = try access.scrub();
    const digest = std.fmt.bytesToHex(result.sha256, .lower);
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .inode = inode,
        .generation = access.data.session.identity.generation,
        .next_sequence = result.next_sequence,
        .size = result.size,
        .replicas_equal = true,
        .sealed = access.data.seal != null,
        .sha256 = @as([]const u8, &digest),
    }, .{});
    defer ctx.allocator.free(json);
    try ctx.writer.print("{s}\n", .{json});
}

fn remoteLookup(ctx: zli.CommandContext) !void {
    const data = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .parent = try std.fmt.parseUnsigned(u64, ctx.getArg("parent").?, 10), .name = ctx.getArg("name").? }, .{});
    defer ctx.allocator.free(data);
    try remote(ctx, "Lookup", data);
}

fn remoteList(ctx: zli.CommandContext) !void {
    const after = ctx.flag("after", []const u8);
    const data = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .parent = try std.fmt.parseUnsigned(u64, ctx.getArg("parent").?, 10), .after = if (after.len == 0) @as(?[]const u8, null) else after, .limit = ctx.flag("limit", i32) }, .{});
    defer ctx.allocator.free(data);
    try remote(ctx, "List", data);
}

fn serveNode(ctx: zli.CommandContext) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cluster_id: nas.raft.ClusterId = undefined;
    const cluster_text = ctx.flag("cluster-id", []const u8);
    if (cluster_text.len != 32) return error.InvalidClusterId;
    _ = try std.fmt.hexToBytes(&cluster_id, cluster_text);
    var peers: std.ArrayList(nas.raft.Peer) = .empty;
    var parts = std.mem.splitScalar(u8, ctx.flag("peers", []const u8), ',');
    while (parts.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidPeer;
        try peers.append(allocator, .{ .id = try std.fmt.parseUnsigned(u64, part[0..split], 10), .context = part[split + 1 ..] });
    }
    const config: nas.runtime.Config = .{
        .node_id = try std.fmt.parseUnsigned(u64, ctx.flag("node-id", []const u8), 10),
        .cluster_id = cluster_id,
        .raft_listen = ctx.flag("raft-listen", []const u8),
        .api_listen = ctx.flag("api-listen", []const u8),
        .data_dir = ctx.flag("data-dir", []const u8),
        .peers = peers.items,
        .snapshot_entries = try std.fmt.parseUnsigned(u64, ctx.flag("snapshot-entries", []const u8), 10),
    };
    try config.validate();
    try nas.raft.log.initGlobal(std.heap.smp_allocator, ctx.io, false);
    defer nas.raft.log.deinitGlobal(std.heap.smp_allocator);
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = signal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var old_int: std.posix.Sigaction = undefined;
    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &old_int);
    defer std.posix.sigaction(.INT, &old_int, null);
    std.posix.sigaction(.TERM, &action, &old_term);
    defer std.posix.sigaction(.TERM, &old_term, null);
    const runtime = try nas.runtime.Runtime.create(std.heap.smp_allocator, config);
    defer runtime.destroy();
    while (!stopping.load(.acquire) and !runtime.exited.load(.acquire)) try ctx.io.sleep(.fromMilliseconds(100), .awake);
    runtime.shutdown();
    if (runtime.failed.load(.acquire)) return error.RaftDriverFailed;
}

fn signal(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

fn demo(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const writer = ctx.writer;
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
