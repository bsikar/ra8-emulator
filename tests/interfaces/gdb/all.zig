//! Tests for src/interfaces/gdb, the GDB remote serial protocol server.
test {
    _ = @import("rsp_packet_test.zig");
    _ = @import("rsp_features_test.zig");
    _ = @import("rsp_dispatch_test.zig");
    _ = @import("rsp_units_test.zig");
}
