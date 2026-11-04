const std = @import("std");
const raft = @import("raftz");
const runtime = @import("runtime.zig");

test "three-voter config rejects duplicate or missing identities and invalid endpoints" {
    var peers = [_]raft.Peer{
        .{ .id = 1, .context = "127.0.0.1:9001" },
        .{ .id = 2, .context = "127.0.0.1:9002" },
        .{ .id = 3, .context = "127.0.0.1:9003" },
    };
    var config: runtime.Config = .{
        .node_id = 1,
        .cluster_id = @splat(1),
        .raft_listen = "127.0.0.1:9001",
        .api_listen = "127.0.0.1:8001",
        .data_dir = "node-1",
        .peers = &peers,
    };
    try config.validate();
    peers[2].id = 2;
    try std.testing.expectError(error.InvalidConfig, config.validate());
    peers[2].id = 3;
    peers[2].context = peers[1].context;
    try std.testing.expectError(error.InvalidConfig, config.validate());
    peers[2].context = "127.0.0.1:9003";
    config.node_id = 4;
    try std.testing.expectError(error.InvalidConfig, config.validate());
    config.node_id = 1;
    config.api_listen = config.raft_listen;
    try std.testing.expectError(error.InvalidConfig, config.validate());
    try std.testing.expectError(error.InvalidEndpoint, runtime.endpoint("127.0.0.1:0"));
}
