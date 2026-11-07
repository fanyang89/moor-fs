//! Test-only process checkpoints. Normal builds do not read the environment or stop.
const std = @import("std");
const enabled = @import("build_options").fault_injection;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn raise(signal: c_int) c_int;

pub fn checkpoint(comptime point: enum { before_replace, after_replace, after_sync, mutable_created, mutable_wal_created, mutable_seal_restored, mutable_checkpoint_reconciled, mutable_first_chunk, mutable_synced, seal_first_published, seal_published, seal_first_invalidated, seal_invalidated }) void {
    if (!enabled) return;
    const selected = getenv("NAS_FS_REPAIR_STOP") orelse return;
    if (std.mem.eql(u8, std.mem.span(selected), @tagName(point))) {
        // Linux SIGSTOP: the harness observes waitpid(WUNTRACED), then kills or resumes.
        _ = raise(@intCast(@backingInt(std.os.linux.SIG.STOP)));
    }
}
