pub const metadata = @import("metadata.zig");
pub const machine = @import("machine.zig");
pub const Machine = machine.Machine;

test {
    _ = @import("metadata_test.zig");
    _ = @import("machine_test.zig");
}
