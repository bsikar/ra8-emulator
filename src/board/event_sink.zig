//! Board-to-session event sink contract (RA8EMU-192).
const reset = @import("../periph/reset.zig");

pub const EventSink = struct {
    context: *anyopaque,
    resetFn: *const fn (*anyopaque, reset.Source, u64) void,
};
