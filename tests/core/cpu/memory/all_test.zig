//! Covers src/core/cpu/memory/all.zig by pulling in each file's tests.
test {
    _ = @import("store_test.zig");
    _ = @import("memory_bus_test.zig");
}
