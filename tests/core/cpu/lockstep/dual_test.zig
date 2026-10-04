//! Covers src/core/cpu/lockstep/dual.zig: CPU1 under --cpu lockstep
//! --cpu1 (RA8EMU-235).
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const Cpu1 = ra8.core.cpu.lockstep.dual.Cpu1;
const Engine = ra8.core.engine.Engine;

const base = memmap.sram_base;

/// CPU1 built the way `open` builds it, but from code written straight
/// into both sides' shared SRAM instead of an ELF on disk. `mine0` and
/// `theirs0` stand in for CPU0's Zig-side and Unicorn engines.
const World = struct {
    mine0: Engine,
    theirs0: Engine,
    cpu1: Cpu1,

    fn open(self: *World, program: []const u16) !void {
        var image: [32]u8 = @splat(0);
        std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
        std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
        for (program, 0..) |half, i| std.mem.writeInt(u16, image[8 + 2 * i ..][0..2], half, .little);
        self.mine0 = try Engine.open();
        self.theirs0 = try Engine.open();
        try self.mine0.mapBoardRam();
        try self.theirs0.mapBoardRam();
        try self.mine0.write(base, &image);
        try self.theirs0.write(base, &image);
        self.cpu1.allocator = std.testing.allocator;
        self.cpu1.bytes = try std.testing.allocator.alloc(u8, 0);
        self.cpu1.attached = false;
        self.cpu1.second = .{ .core = try Engine.open(), .state = .{ .vector_base = base } };
        try self.cpu1.second.core.shareBoardRamWith(&self.theirs0);
        try self.cpu1.attachWith(&self.mine0, null);
    }

    fn close(self: *World) void {
        self.cpu1.close();
        self.theirs0.close();
        self.mine0.close();
    }
};

test "each round checks CPU1's share and counts it the Unicorn way" {
    var world: World = undefined;
    // B . : a core that runs every instruction it is given.
    try world.open(&.{0xE7FE});
    defer world.close();
    try world.cpu1.round(100);
    try world.cpu1.round(100);
    try std.testing.expectEqual(@as(usize, 2), world.cpu1.second.state.turns);
    try std.testing.expectEqual(@as(usize, 200), world.cpu1.second.state.ran);
    try std.testing.expectEqual(base + 8, world.cpu1.second.state.pc);
    try std.testing.expect(world.cpu1.clean());
}

test "a clean CPU1 reports no divergence under its own prefix" {
    var world: World = undefined;
    try world.open(&.{0xE7FE});
    defer world.close();
    try world.cpu1.round(10);
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try world.cpu1.write(stream.writer());
    const text = stream.getWritten();
    try std.testing.expect(std.mem.startsWith(u8, text, "cpu1: 10 instructions checked over 1 turns\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "cpu1 lockstep: budget spent, no divergence\n") != null);
}

test "a CPU1 whose Zig core stops is not clean and takes no more" {
    var world: World = undefined;
    // movs r0, #1 ; ba80, unallocated on Armv8-M.
    try world.open(&.{ 0x2001, 0xBA80 });
    defer world.close();
    try world.cpu1.round(100);
    try std.testing.expect(!world.cpu1.clean());
    const ran = world.cpu1.second.state.ran;
    try world.cpu1.round(100);
    try std.testing.expectEqual(ran, world.cpu1.second.state.ran);
}
