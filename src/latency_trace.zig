//! Compile-time opt-in diagnostics; ordinary builds perform no clock reads or logging.
const std = @import("std");
const enabled = @import("build_options").latency_trace;

pub fn Timing(comptime count: usize) type {
    return struct {
        last: u64,
        stages: [count]u64 = @splat(0),

        const Self = @This();

        pub fn start() Self {
            return .{ .last = now() };
        }

        pub fn mark(self: *Self, comptime index: usize) void {
            if (!enabled) return;
            const end = now();
            self.stages[index] = end -| self.last;
            self.last = end;
        }

        pub fn finish(self: Self, comptime operation: []const u8, id: u64, size: u64, wal: u64) void {
            if (!enabled) return;
            std.log.info("latency op={s} id={d} size={d} wal={d} ns={any}", .{ operation, id, size, wal, self.stages });
        }
    };
}

fn now() u64 {
    if (!enabled) return 0;
    var time: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &time) != 0) return 0;
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}
