//! Covers src/core/cpu/lockstep/second.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const second = ra8.core.cpu.lockstep.second;
const oracle = ra8.core.cpu.lockstep.oracle;
const Engine = ra8.core.engine.Engine;

const base = memmap.sram_base;

/// A vector table at the base of SRAM, then movs r0,#5 ; adds r0,#3 ;
/// nop ; ba80, unallocated on Armv8-M, so CPU1's Zig core stops there.
fn tiny() [16]u8 {
    var image: [16]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..16], &[_]u8{ 0x05, 0x20, 0x03, 0x30, 0x00, 0xBF, 0x80, 0xBA });
    return image;
}

const World = struct {
    ours0: Engine,
    theirs0: Engine,
    theirs1: Engine,

    fn open(self: *World) !void {
        const image = tiny();
        self.ours0 = try Engine.open();
        self.theirs0 = try Engine.open();
        self.theirs1 = try Engine.open();
        try self.ours0.mapBoardRam();
        try self.theirs0.mapBoardRam();
        try self.theirs1.shareBoardRamWith(&self.theirs0);
        try self.ours0.write(base, &image);
        try self.theirs0.write(base, &image);
    }

    fn close(self: *World) void {
        self.theirs1.close();
        self.theirs0.close();
        self.ours0.close();
    }
};

test "CPU1's Zig core matches CPU1's Unicorn engine until it stops" {
    var world: World = undefined;
    try world.open();
    defer world.close();
    var pair: second.Pair = undefined;
    try pair.open(&world.ours0, world.theirs1, null, base);
    defer pair.close();
    try std.testing.expectEqual(base + 8, pair.cpu.regs.pc);
    try pair.turn(100);
    try std.testing.expect(pair.ended != null);
    try std.testing.expect(pair.ended.? == .stopped);
    try std.testing.expectEqual(@as(u32, 8), pair.cpu.regs.get(0));
    const theirs = try oracle.read(world.theirs1);
    try std.testing.expectEqual(@as(u32, 8), theirs.get(.r0).?);
}

test "a turn after CPU1's check ended changes nothing" {
    var world: World = undefined;
    try world.open();
    defer world.close();
    var pair: second.Pair = undefined;
    try pair.open(&world.ours0, world.theirs1, null, base);
    defer pair.close();
    try pair.turn(100);
    const pc = pair.cpu.regs.pc;
    try pair.turn(100);
    try std.testing.expectEqual(pc, pair.cpu.regs.pc);
}

test "CPU1's Zig side shares SRAM with CPU0's Zig side" {
    var world: World = undefined;
    try world.open();
    defer world.close();
    var pair: second.Pair = undefined;
    try pair.open(&world.ours0, world.theirs1, null, base);
    defer pair.close();
    try world.ours0.write(base + 0x800, &[_]u8{ 0x5A, 0xA5 });
    var seen: [2]u8 = undefined;
    try pair.mine.read(base + 0x800, &seen);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x5A, 0xA5 }, &seen);
}
