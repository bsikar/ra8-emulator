//! Tests for src/core/engine.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const mod = ra8.core.engine;

const Engine = mod.Engine;

test "an engine opens, maps the board, and reads back what it wrote" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.write(memmap.sram_base, &[_]u8{ 0x0D, 0xF0, 0xAD, 0x0B });
    try std.testing.expectEqual(@as(u32, 0x0BADF00D), try engine.readWord(memmap.sram_base));
    try engine.setRegister(.sp, memmap.sram_base + 0x100);
    try std.testing.expectEqual(memmap.sram_base + 0x100, try engine.register(.sp));
}

test "address zero is not mapped, so a startup copy from it is refused" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    if (engine.readWord(memmap.itcm_base)) |_| return error.TestUnexpectedResult else |_| {}
}

test "a reset takes SP and PC from the vector table and leaves LR all ones" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    const table = memmap.sram_base;
    try engine.write(table, &[_]u8{ 0x00, 0x10, 0x00, 0x22, 0x41, 0x02, 0x00, 0x22 });
    try engine.setRegister(.lr, 0);
    try engine.resetFromVectorTable(table);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), try engine.register(.sp));
    try std.testing.expectEqual(@as(u32, 0x2200_0240), try engine.register(.pc));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try engine.register(.lr));
}

test "a read past the bytes an image loads still lands in code MRAM" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.write(memmap.mram_base + 0x8_0000, &[_]u8{ 0x00, 0x00, 0x18, 0x32 });
    try std.testing.expectEqual(@as(u32, 0x3218_0000), try engine.readWord(memmap.mram_base + 0x8_0000));
    try std.testing.expectEqual(@as(u32, 0), try engine.readWord(memmap.mram_base + 0x8_1000));
}
