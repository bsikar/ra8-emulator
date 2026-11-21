//! Unit tests for RA4T1 `GPT16E0..5` (`0x4016_9000`) and `AGT0..1` (`0x400E_8000`).
const ra8 = @import("ra8");
const std = @import("std");

const timers = ra8.chip.vendor.renesas.ra4t1.timers;

test "GPT16E0 wraps 16-bit counter and queues GPT0_OVF (0x0C6)" {
    var unit = timers.Timers.init();
    const ch0 = timers.gpt_base;
    try std.testing.expectEqual(@as(u32, 0xFFFF), unit.readGpt(ch0 + timers.gpt_ofs.gtpr, 4));

    unit.writeGpt(ch0 + timers.gpt_ofs.gtpr, 4, 99);
    unit.writeGpt(ch0 + timers.gpt_ofs.gtcr, 4, 1);
    unit.tick(10_000, 20_000_000, 20_000_000); // 200 ticks -> 2 wraps
    try std.testing.expectEqual(@as(u64, 2), unit.gpt[0].wraps);
    const events = unit.takeEvents();
    try std.testing.expectEqualSlices(u16, &.{0x0C6}, events.slice());
}

test "AGT0 down-counts and queues AGT0_INT (0x040)" {
    var unit = timers.Timers.init();
    const ch0 = timers.agt_base;
    unit.writeAgt(ch0 + timers.agt_ofs.agt, 2, 49);
    unit.writeAgt(ch0 + timers.agt_ofs.agtcr, 1, 0x01);
    unit.tick(5_000, 20_000_000, 20_000_000); // 100 ticks -> 2 underflows
    try std.testing.expectEqual(@as(u64, 2), unit.agt[0].underflows);
    const events = unit.takeEvents();
    try std.testing.expectEqualSlices(u16, &.{0x040}, events.slice());
}
