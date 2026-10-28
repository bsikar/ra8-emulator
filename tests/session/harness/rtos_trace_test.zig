//! Tests for src/session/harness/rtos_trace.zig: an image without ThreadX
//! gets no tracer, so there is nothing to trace or observe.
const std = @import("std");
const rig = @import("../history/window_rig.zig");

test "an image without ThreadX gets no tracer and no observer" {
    var opened = try rig.openCounting(std.testing.allocator, null);
    defer opened.deinit();
    try std.testing.expect(!opened.traceIfRtos());
    try std.testing.expect(!opened.observeRtos(null));
    try std.testing.expect(!opened.traceRtos());
}
