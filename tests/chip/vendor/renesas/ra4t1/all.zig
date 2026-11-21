//! Tests for RA4T1 silicon machine and peripheral blocks (`src/chip/vendor/renesas/ra4t1/`).
test {
    _ = @import("fcache_test.zig");
    _ = @import("flash_ctrl_test.zig");
    _ = @import("icu_test.zig");
    _ = @import("machine_test.zig");
    _ = @import("mstp_test.zig");
    _ = @import("port_test.zig");
    _ = @import("pscu_test.zig");
    _ = @import("ra4t1_test.zig");
    _ = @import("sci_test.zig");
    _ = @import("snapshot_test.zig");
    _ = @import("sysc_test.zig");
    _ = @import("timers_test.zig");
}
