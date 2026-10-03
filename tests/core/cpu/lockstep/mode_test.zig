//! Covers src/core/cpu/lockstep/mode.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const mode = ra8.core.cpu.lockstep.mode;
const Engine = ra8.core.engine.Engine;

/// A vector table at the base of SRAM pointing at code right after it:
/// bf00 nop ; f3af 8000 nop.w ; ba80, unallocated on Armv8-M.
fn loadTiny(core: *Engine) !void {
    const base = memmap.sram_base;
    var image: [16]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..16], &[_]u8{ 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x80, 0xBA });
    try core.mapBoardRam();
    try core.write(base, &image);
}

test "a lockstep run reports where it stopped and prints the class table" {
    var mine = try Engine.open();
    defer mine.close();
    var theirs = try Engine.open();
    defer theirs.close();
    try loadTiny(&mine);
    try loadTiny(&theirs);
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const status = try mode.runLoaded(stream.writer(), &mine, theirs, memmap.sram_base, 100, null);
    try std.testing.expectEqual(@as(u8, 1), status);
    const text = stream.getWritten();
    try std.testing.expect(std.mem.startsWith(u8, text, "lockstep: zig core stopped, unknown encoding at "));
    try std.testing.expect(std.mem.indexOf(u8, text, "| hint | 2 | 0 | 0 |\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "| total | 2 | 0 | 0 |\n"));
}

test "with no vector table there is nothing to lockstep" {
    var mine = try Engine.open();
    defer mine.close();
    var theirs = try Engine.open();
    defer theirs.close();
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try std.testing.expectEqual(@as(u8, 1), try mode.runLoaded(stream.writer(), &mine, theirs, memmap.sram_base, 10, null));
}

test {
    _ = @import("second_test.zig");
}
