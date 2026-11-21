//! Covers src/chip/vendor/himax/hx6538/timer.zig: CMSDK APB Timer0..8 countdown, reload, and W1C IRQ.
const ra8 = @import("ra8");
const std = @import("std");

const timer = ra8.chip.vendor.himax.hx6538.timer;

test "CMSDK timer counts down, fires IRQ at zero, reloads RELOAD, and clears on W1C" {
    var bank: timer.Bank = .{};
    const ch = &bank.channels[0];
    ch.write(timer.regs.reload, 9);
    ch.write(timer.regs.value, 9);
    ch.write(timer.regs.ctrl, timer.ctrl_bits.enable | timer.ctrl_bits.irq_enable);

    try std.testing.expect(!ch.tickCycles(5));
    try std.testing.expectEqual(@as(u32, 4), ch.read(timer.regs.value));
    try std.testing.expect(!ch.irqAsserted());

    // Remaining 4 ticks reach zero and raise IRQ; next tick reloads RELOAD=9.
    try std.testing.expect(ch.tickCycles(4));
    try std.testing.expectEqual(@as(u32, 0), ch.read(timer.regs.value));
    try std.testing.expect(ch.irqAsserted());

    ch.write(timer.regs.int_status, 1);
    try std.testing.expect(!ch.irqAsserted());

    // 1 tick wraps 0 -> 9, 10 more ticks reach 0 (tick 10) and reload 9 (tick 11).
    try std.testing.expect(!ch.tickCycles(1));
    try std.testing.expectEqual(@as(u32, 9), ch.read(timer.regs.value));
    try std.testing.expect(ch.tickCycles(10));
    try std.testing.expectEqual(@as(u32, 9), ch.read(timer.regs.value));
    try std.testing.expect(ch.irqAsserted());

    ch.write(timer.regs.int_status, 1);
    try std.testing.expect(ch.tickCycles(9));
    try std.testing.expectEqual(@as(u32, 0), ch.read(timer.regs.value));
    ch.write(timer.regs.int_status, 1);
    try std.testing.expect(ch.tickCycles(11));
    try std.testing.expectEqual(@as(u32, 9), ch.read(timer.regs.value));
    try std.testing.expect(ch.irqAsserted());
}
