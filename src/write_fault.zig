//! Nonempty FUSE staging/publication checkpoints, available only in test builds.
const std = @import("std");
const enabled = @import("build_options").fault_injection;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn raise(signal: c_int) c_int;

pub fn checkpoint(comptime point: enum { first_stage_write, first_replica, both_replicas, published }, size: u64) void {
    if (!enabled or size == 0) return;
    const selected = getenv("MOOR_FS_WRITE_STOP") orelse return;
    if (std.mem.eql(u8, std.mem.span(selected), @tagName(point))) {
        _ = raise(@intCast(@backingInt(std.os.linux.SIG.STOP)));
    }
}
