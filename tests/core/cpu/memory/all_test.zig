//! Covers src/core/cpu/memory/all.zig by pulling in each file's tests.
test {
    _ = @import("store_test.zig");
    _ = @import("memory_bus_test.zig");
    _ = @import("guest_test.zig");
    _ = @import("guest_bus_test.zig");
    _ = @import("load_test.zig");
    _ = @import("extra_test.zig");
    _ = @import("initiator_test.zig");
}
