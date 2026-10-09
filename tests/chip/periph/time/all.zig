//! Tests for src/chip/periph/time/.
test {
    _ = @import("timebase_test.zig");
    _ = @import("event_queue_test.zig");
    _ = @import("systick_due_test.zig");
    _ = @import("speed_invariance_test.zig");
    _ = @import("rtc_day_test.zig");
}
