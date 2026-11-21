//! Covers src/chip/vendor/himax/hx6538/hx6538.zig: IRQ constants and peripheral bundle defaults.
const ra8 = @import("ra8");
const std = @import("std");

const hx6538 = ra8.chip.vendor.himax.hx6538;

test "HX6538 peripheral bundle uses verified WE2 IRQ numbers and cold-boot state" {
    try std.testing.expectEqual(@as(u16, 7), hx6538.irqs.mailbox);
    try std.testing.expectEqual(@as(u16, 34), hx6538.irqs.timer_base_0);
    try std.testing.expectEqual(@as(u16, 47), hx6538.irqs.timer_base_6);
    try std.testing.expectEqual(@as(u16, 90), hx6538.irqs.uart0);
    try std.testing.expectEqual(@as(u16, 91), hx6538.irqs.uart1);
    try std.testing.expectEqual(@as(u16, 95), hx6538.irqs.uart2);
    try std.testing.expectEqual(@as(u16, 192), hx6538.irqs.ethos_u55);
    try std.testing.expectEqual(@as(u16, 224), hx6538.irqs.lines);
    const p: hx6538.Periph = .{};
    try std.testing.expect(!p.scu.cm55sRunning());
}
