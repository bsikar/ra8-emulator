//! Covers src/core/cpu/engine_bus.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const bus = ra8.core.cpu.bus;
const Engine = ra8.core.engine.Engine;
const EngineBus = ra8.core.cpu.engine_bus.EngineBus;

test "the Zig core reads and writes the bytes Unicorn holds" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.write(memmap.sram_base, &.{ 0x00, 0xBF, 0xAF, 0xF3 });
    var memory: EngineBus = .{ .core = &core };
    const view = memory.view();
    try std.testing.expectEqual(@as(u32, 0xF3AF_BF00), try view.readWord(memmap.sram_base));
    try view.write(memmap.sram_base + 8, &.{ 0x0D, 0xF0, 0xAD, 0x0B });
    try std.testing.expectEqual(@as(u32, 0x0BAD_F00D), try core.readWord(memmap.sram_base + 8));
}

test "memory Unicorn has not mapped is unmapped to the Zig core too" {
    var core = try Engine.open();
    defer core.close();
    var memory: EngineBus = .{ .core = &core };
    try std.testing.expectError(bus.Error.Unmapped, memory.view().readHalf(memmap.sram_base));
}
