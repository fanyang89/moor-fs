const nas = @import("nas_fs");
const std = @import("std");
const zli = @import("zli");

pub fn serve(ctx: zli.CommandContext) !void {
    const mappings = try nas.objects.loadMappings(ctx.allocator, ctx.io, ctx.getArg("config").?);
    defer mappings.deinit();
    var rpc: nas.mutable_rpc.Client = .{ .allocator = ctx.allocator, .endpoints = ctx.getArg("endpoint").? };
    const pair = .{
        try std.fmt.parseUnsigned(u64, ctx.getArg("first-backend").?, 10),
        try std.fmt.parseUnsigned(u64, ctx.getArg("second-backend").?, 10),
    };
    if (pair[0] == 0 or pair[1] == 0 or pair[0] == pair[1]) return error.InvalidReplicaPolicy;
    var service: nas.file_service.Service = .{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .metadata = rpc.api(),
        .mappings = mappings.value,
        .migration_pair = pair,
    };
    defer service.deinit();
    try nas.file_ipc.serve(&service, ctx.getArg("runtime-directory").?);
}
