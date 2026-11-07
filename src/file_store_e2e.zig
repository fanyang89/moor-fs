//! Test-only driver for real CIFS persistence and process-death acceptance.
const std = @import("std");
const nas = @import("moor_fs");
extern "c" fn raise(signal: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const action = args.next() orelse return error.MissingAction;
    const a = args.next() orelse return error.MissingBackend;
    const b = args.next() orelse return error.MissingBackend;
    if (args.next() != null) return error.UnexpectedArgument;
    const io = init.io;
    const first = try std.Io.Dir.cwd().openDir(io, a, .{ .iterate = true, .follow_symlinks = false });
    defer first.close(io);
    const second = try std.Io.Dir.cwd().openDir(io, b, .{ .iterate = true, .follow_symlinks = false });
    defer second.close(io);
    const identity: nas.file_wal.Identity = .{ .inode = 42, .generation = 9 };
    const create = std.mem.eql(u8, action, "create");
    var store = if (create)
        try nas.file_store.Store.create(init.gpa, io, identity, .{ first, second })
    else
        try nas.file_store.Store.open(init.gpa, io, identity, .{ first, second });
    defer store.close();
    if (create) {
        try store.write("baseline", 0);
        try store.sync();
        try store.collect();
    } else if (std.mem.eql(u8, action, "verify")) {
        for (store.session.replicas) |replica| {
            var bytes: [8]u8 = undefined;
            if ((try replica.data.stat(io)).size != bytes.len or try replica.data.readPositionalAll(io, &bytes, 0) != bytes.len or !std.mem.eql(u8, &bytes, "baseXYne")) return error.ContentMismatch;
        }
    } else {
        if (!std.mem.eql(u8, action, "write") and !std.mem.eql(u8, action, "checkpoint") and !std.mem.eql(u8, action, "collect")) return error.InvalidAction;
        try store.write("X", 4);
        try store.write("Y", 5);
        if (!std.mem.eql(u8, action, "write")) try store.sync();
        if (std.mem.eql(u8, action, "collect")) try store.collect();
        _ = raise(@intCast(@backingInt(std.os.linux.SIG.STOP)));
        return error.ExpectedKill;
    }
}
