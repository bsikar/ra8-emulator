//! Covers src/core/cpu/lockstep/seed.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;
const seed = ra8.core.cpu.lockstep.seed;

const dwt_ctrl: u32 = 0xE000_1000;

test "the PPB the oracle was wired with reaches the Zig core's engine" {
    var mine = try Engine.open();
    defer mine.close();
    var theirs = try Engine.open();
    defer theirs.close();
    try mine.mapBoardRam();
    try theirs.mapBoardRam();
    try theirs.writeWord(dwt_ctrl, 0x8000_0000);
    try std.testing.expectEqual(@as(u32, 0), try mine.readWord(dwt_ctrl));
    const copied = seed.ppb(mine, theirs);
    try std.testing.expectEqual(memmap.ppb_size / seed.page, copied);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try mine.readWord(dwt_ctrl));
}

test "the board RAM outside the PPB is left alone" {
    var mine = try Engine.open();
    defer mine.close();
    var theirs = try Engine.open();
    defer theirs.close();
    try mine.mapBoardRam();
    try theirs.mapBoardRam();
    try theirs.writeWord(memmap.sram_base, 0x1234_5678);
    _ = seed.ppb(mine, theirs);
    try std.testing.expectEqual(@as(u32, 0), try mine.readWord(memmap.sram_base));
}
