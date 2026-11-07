//! Test-only end-to-end driver: guarded NAS access plus live Raft metadata.
const std = @import("std");
const nas = @import("moor_fs");
extern "c" fn raise(signal: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const endpoints = args.next() orelse return error.MissingEndpoint;
    const config = args.next() orelse return error.MissingConfig;
    const inode = try std.fmt.parseUnsigned(u64, args.next() orelse return error.MissingInode, 10);
    const action = args.next() orelse return error.MissingAction;
    if (args.next() != null) return error.UnexpectedArgument;
    const mappings = try nas.objects.loadMappings(init.gpa, init.io, config);
    defer mappings.deinit();
    var metadata: nas.mutable_rpc.Client = .{ .allocator = init.gpa, .endpoints = endpoints };
    var file = try nas.mutable_access.Access.open(init.gpa, init.io, metadata.api(), mappings.value, inode, .{ 1, 2 });
    defer file.close();
    if (std.mem.eql(u8, action, "migrate") or std.mem.eql(u8, action, "verify")) {
        var bytes: [9]u8 = undefined;
        const expected = if (std.mem.eql(u8, action, "migrate")) "baseline" else "baseXYne";
        const count = try file.read(&bytes, 0);
        if (count != expected.len or !std.mem.eql(u8, bytes[0..count], expected)) return error.ContentMismatch;
        if (std.mem.eql(u8, action, "migrate")) try file.collect();
        return;
    }
    if (!std.mem.eql(u8, action, "write") and !std.mem.eql(u8, action, "checkpoint") and !std.mem.eql(u8, action, "collect")) return error.InvalidAction;
    try file.write("X", 4);
    try file.write("Y", 5);
    if (!std.mem.eql(u8, action, "write")) try file.sync();
    if (std.mem.eql(u8, action, "collect")) try file.collect();
    _ = raise(@intCast(@backingInt(std.os.linux.SIG.STOP)));
    return error.ExpectedKill;
}
