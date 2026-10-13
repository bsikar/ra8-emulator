//! A SysTick observer retains the inner bus and its non-store capabilities.
const std = @import("std");
const ra8 = @import("ra8");
const ram = @import("../../chip/core/cpu/exception/ram.zig");

test "grid strict cut bus forwards accesses and status latches without extra cuts" {
    var memory: ram.Ram = .{};
    var clock: ra8.chip.periph.clocks.Clocks = .{};
    var cut: ra8.chip.core.cpu.cpu.systick_cut.Cut = .{ .clocks = .{ &clock, null } };
    var wrapper: ra8.session.zig.cut_bus.CutBus = .{ .inner = memory.view(), .cut = &cut };
    const bus = wrapper.view();
    const map = ra8.chip.core.memmap;
    try bus.writeWord(map.syst.rvr, 4);
    try std.testing.expect(!cut.take());
    try bus.writeWord(map.syst.csr, 5);
    try std.testing.expect(cut.take());
    try bus.writeWord(map.syst.rvr, 9);
    try std.testing.expect(cut.take());
    try std.testing.expectEqual(@as(u32, 9), try bus.readWord(map.syst.rvr));
    try bus.latch(map.scb.icsr, 1 << 26);
    try std.testing.expectEqual(@as(u32, 1 << 26), memory.word(map.scb.icsr));
    try std.testing.expect(!cut.take());
    try std.testing.expectEqual(@as(u64, 2), clock.rearms);
    var word: [4]u8 = undefined;
    try std.testing.expect(!bus.peek(map.scb.icsr, &word));
    try std.testing.expect(!bus.repeat(map.scb.icsr, 4, 0));
}
