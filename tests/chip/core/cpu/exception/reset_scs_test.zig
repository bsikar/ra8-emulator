//! Covers reset_scs.zig: every implemented IRQ word and both SCS banks.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;
const reset = ra8.chip.core.cpu.reset.scs;

test "CPU foundation SCS reset clears last IRQ and priority words in both banks" {
    var ram = fixture.Ram{};
    const lines = [_]u32{ memmap.nvic.iser, memmap.nvic.icer, memmap.nvic.ispr, memmap.nvic.icpr, memmap.nvic.iabr };
    for ([_]u32{ 0, 0x20000 }) |offset| {
        for (lines) |base| {
            for (0..3) |i| ram.putWord(base + offset + @as(u32, @intCast(i * 4)), 0xFFFF_FFFF);
        }
        for (0..24) |i| ram.putWord(memmap.nvic.ipr + offset + @as(u32, @intCast(i * 4)), 0xFFFF_FFFF);
        ram.putWord(memmap.scb.shcsr + offset, 0xFFFF_FFFF);
        ram.putWord(memmap.scb.icsr + offset, 0xFFFF_FFFF);
    }
    try reset.clear(ram.view());
    for ([_]u32{ 0, 0x20000 }) |offset| {
        for (lines) |base| {
            for (0..3) |i| try std.testing.expectEqual(@as(u32, 0), ram.word(base + offset + @as(u32, @intCast(i * 4))));
        }
        for (0..24) |i| try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.nvic.ipr + offset + @as(u32, @intCast(i * 4))));
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.shcsr + offset));
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.icsr + offset));
    }
}
