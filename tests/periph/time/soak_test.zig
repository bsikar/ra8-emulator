//! Tests for src/periph/time/soak.zig.
const std = @import("std");
const ra8 = @import("ra8");
const soak = ra8.periph.clocks.soak;

test "an unarmed soak ignores events and prints nothing" {
    var state = soak.Soak{};
    state.note(.watchdog_reset, 5);
    try std.testing.expect(!state.ended());
    var buffer: [96]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try state.line(stream.writer());
    try std.testing.expectEqualStrings("", stream.getWritten());
}

test "an armed soak keeps its first event and ends the run on it" {
    var state = soak.Soak{ .armed = true };
    try std.testing.expect(!state.ended());
    state.note(.iwdt_reset, 3_600_000_000_123);
    state.note(.watchdog_reset, 3_700_000_000_000);
    try std.testing.expect(state.ended());
    try std.testing.expectEqual(soak.Kind.iwdt_reset, state.event.?.kind);
    var buffer: [96]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try state.line(stream.writer());
    try std.testing.expectEqualStrings("soak: stopped on watchdog reset (IWDT) at 3600.000000123 s virtual\n", stream.getWritten());
}

test "an armed soak with nothing to report says so" {
    const state = soak.Soak{ .armed = true };
    var buffer: [96]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try state.line(stream.writer());
    try std.testing.expectEqualStrings("soak: no events\n", stream.getWritten());
}
