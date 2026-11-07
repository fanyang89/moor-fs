//! One-shot metadata reply loss checkpoint for explicitly instrumented tests.
const std = @import("std");
const enabled = @import("build_options").fault_injection;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn raise(signal: c_int) c_int;

pub fn beforeReply(inode: u64, request_id: u64) void {
    if (!enabled) return;
    const directory = getenv("MOOR_FS_PUBLISH_STOP_DIR") orelse return;
    var buffer: [4096]u8 = undefined;
    const path = std.mem.printSentinel(&buffer, "{s}/{d}", .{ std.mem.span(directory), inode }, 0) catch return;
    // Consuming the inode marker atomically keeps the retry on the new leader running.
    if (unlink(path) == 0) {
        std.debug.print("MOOR_FS_PUBLISH_STOP inode={d} request={d}\n", .{ inode, request_id });
        _ = raise(@intCast(@backingInt(std.os.linux.SIG.STOP)));
    }
}
