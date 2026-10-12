//! Folds the session's events into the board pane's LEDs (RA8EMU-1081).
//! The session reports the board's parts (RA8EMU-1151), so the fold guards
//! with the LED count the board_parts answer gave; the GUI never imports
//! the chip, and a change past the reported count is not an LED here.
const proto = @import("ra8_rpc").session.rpc;
const board_pane = @import("../ui/board_pane.zig");

/// Takes one session event; anything but a reported LED's change is ignored.
pub fn observe(leds: *board_pane.Leds, led_count: usize, event: proto.SessionEvent) void {
    if (event.kind != .led_changed) return;
    const index = event.address & 0xFF;
    if (index >= led_count or index >= board_pane.max_leds) return;
    leds.on[index] = event.address & 0x100 != 0;
}
