//! Covers src/core/cpu/exception/all.zig.
test {
    _ = @import("exc_return_test.zig");
    _ = @import("frame_test.zig");
    _ = @import("entry_test.zig");
    _ = @import("ret_test.zig");
    _ = @import("active_test.zig");
    _ = @import("source_test.zig");
    _ = @import("dispatch_test.zig");
    _ = @import("nvic_source_test.zig");
    _ = @import("fault_test.zig");
    _ = @import("sleep_test.zig");
}
