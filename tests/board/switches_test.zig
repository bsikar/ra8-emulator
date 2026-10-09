//! Tests for src/board/switches.zig.
const std = @import("std");
const ra8 = @import("ra8");
const switches = ra8.board.switches;

test "the EK-RA8D2 switches are SW1 on P009 IRQ13 and SW2 on P008 IRQ12" {
    try std.testing.expectEqual(@as(usize, 2), switches.user.len);
    try std.testing.expectEqualStrings("sw1", switches.user[0].name);
    try std.testing.expectEqual(@as(u8, 0), switches.user[0].port);
    try std.testing.expectEqual(@as(u4, 9), switches.user[0].pin);
    try std.testing.expectEqual(@as(u8, 13), switches.user[0].irq);
    try std.testing.expectEqualStrings("sw2", switches.user[1].name);
    try std.testing.expectEqual(@as(u8, 0), switches.user[1].port);
    try std.testing.expectEqual(@as(u4, 8), switches.user[1].pin);
    try std.testing.expectEqual(@as(u8, 12), switches.user[1].irq);
}

test "pulled port blocks read both switches released, before and after reset" {
    var pins = switches.pulled();
    for (switches.user) |one| try std.testing.expect(pins.pinLevel(one.port, one.pin));
    pins.setInput(0, 9, false);
    pins.reset();
    for (switches.user) |one| try std.testing.expect(pins.pinLevel(one.port, one.pin));
    try std.testing.expect(!pins.pinLevel(0, 7));
}
