//! Tests for src/interfaces/rpc/session_event_feed.zig (RA8EMU-942): which
//! stream events go out on the session topic, and as which wire kind.
const std = @import("std");
const ra8 = @import("ra8");
const feed = ra8.interfaces.rpc.event_feed;
const proto = ra8.interfaces.rpc.session;

test "stream kinds the wire names map to the same wire kind" {
    try std.testing.expectEqual(proto.EventKind.breakpoint_set, feed.wireKind(.breakpoint_set).?);
    try std.testing.expectEqual(proto.EventKind.input_scheduled, feed.wireKind(.input_scheduled).?);
    try std.testing.expectEqual(proto.EventKind.unplugged, feed.wireKind(.unplugged).?);
}

test "stream kinds with their own topic or no wire name are skipped" {
    try std.testing.expect(feed.wireKind(.uart_byte) == null);
    try std.testing.expect(feed.wireKind(.lcd_frame) == null);
    try std.testing.expect(feed.wireKind(.led_changed) == null);
    try std.testing.expect(feed.wireKind(.isr_enter) == null);
}
