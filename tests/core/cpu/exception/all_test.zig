//! Covers src/core/cpu/exception/all.zig.
test {
    _ = @import("exc_return_test.zig");
    _ = @import("frame_test.zig");
    _ = @import("entry_test.zig");
    _ = @import("ret_test.zig");
}
