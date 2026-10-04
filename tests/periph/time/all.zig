//! Tests for src/periph/time/.
test {
    _ = @import("timebase_test.zig");
    _ = @import("event_queue_test.zig");
    _ = @import("systick_due_test.zig");
    _ = @import("pacer_test.zig");
    _ = @import("pacing_test.zig");
    _ = @import("speed_test.zig");
    _ = @import("speed_invariance_test.zig");
    _ = @import("duration_test.zig");
    _ = @import("soak_test.zig");
    _ = @import("soak_fault_test.zig");
}
