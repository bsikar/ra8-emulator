//! The host adapter tests (src/host).
test {
    _ = @import("host_console_test.zig");
    _ = @import("host_read_test.zig");
    _ = @import("camera/pipe_windows_test.zig");
}
