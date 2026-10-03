//! Tests for src/core/second_zig.zig: CPU1 on the Zig core (RA8EMU-234).
const std = @import("std");
const ra8 = @import("ra8");
const second_core = ra8.core.second_core;
const SecondZig = second_core.zig.SecondZig;
const Engine = ra8.core.engine.Engine;
const memmap = ra8.core.memmap;
const Board = ra8.board.Board;

const vectors: u32 = memmap.sram_base + 0x1000;
const code: u32 = vectors + 0x200;
const stack: u32 = vectors + 0x800;
const usage_handler: u32 = vectors + 0x400;
const hard_handler: u32 = vectors + 0x440;
const usgfaultena: u32 = 1 << 18;

/// CPU0's engine with board RAM, and CPU1's engine sharing it, the way
/// `Second.open` sets them up.
fn pair(cpu1: *second_core.Second) !Engine {
    var cpu0 = try Engine.open();
    errdefer cpu0.close();
    try cpu0.mapBoardRam();
    cpu1.* = .{ .core = try Engine.open(), .vector_base = vectors };
    errdefer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    try cpu1.core.writeWord(vectors, stack);
    try cpu1.core.writeWord(vectors + 4, code | 1);
    try cpu1.core.writeWord(vectors + 3 * 4, hard_handler | 1);
    try cpu1.core.writeWord(vectors + 6 * 4, usage_handler | 1);
    return cpu0;
}

fn halves(core: Engine, at: u32, words: []const u16) !void {
    for (words, 0..) |half, i| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, half, .little);
        try core.write(at + @as(u32, @intCast(2 * i)), &bytes);
    }
}

test "CPU1's Zig core resets from CPU1's vector table and runs its turn" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // MOVS r0, #5; ADDS r0, #1; B .
    try halves(cpu1.core, code, &.{ 0x2005, 0x3001, 0xE7FE });

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try std.testing.expectEqual(stack, core.cpu.regs.sp());
    try std.testing.expectEqual(ra8.core.cpu.cpu.Stop.count, core.turn(2));
    try std.testing.expectEqual(@as(u32, 6), core.cpu.regs.get(0));
    try std.testing.expectEqual(@as(u64, 2), core.cpu.retired);
}

test "CPU1's Zig core is an M33 on the CPU1 side of the board" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try std.testing.expectEqual(ra8.core.part.cpu1_profile, core.cpu.profile);
    try std.testing.expectEqual(ra8.periph.registry.Issuer.cpu1, core.board.issuer);
}

test "an MVE op on CPU1's Zig core takes UsageFault, not a step" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // VADD.I32 q0, q1, q2, then B . in each handler.
    try halves(cpu1.core, code, &.{ 0xEF22, 0x0844 });
    try halves(cpu1.core, usage_handler, &.{0xE7FE});
    try halves(cpu1.core, hard_handler, &.{0xE7FE});

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try core.cpu.bus.write(memmap.scb.shcsr, std.mem.asBytes(&usgfaultena));
    try std.testing.expectEqual(ra8.core.cpu.cpu.Stop.count, core.turn(1));
    try std.testing.expectEqual(usage_handler, core.cpu.regs.pc);
    try std.testing.expectEqual(code, try cpu1.core.readWord(core.cpu.regs.sp() + 24));
}

test "CPU1's Zig core polls through its own quiet source (RA8EMU-440)" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // B . with nothing pending: the poll settles and stays settled.
    try halves(cpu1.core, code, &.{0xE7FE});

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try std.testing.expectEqual(&core.quiet, core.cpu.quiet.?);
    try std.testing.expectEqual(ra8.core.cpu.cpu.Stop.count, core.turn(4));
    try std.testing.expect(core.quiet.settled);
    // A RAM store leaves the answer standing; a peripheral store stirs it.
    try core.cpu.bus.write(code + 0x100, &.{ 1, 2, 3, 4 });
    try std.testing.expect(core.quiet.settled);
    core.cpu.bus.write(0x4000_0000, &.{ 0, 0, 0, 0 }) catch {};
    try std.testing.expect(!core.quiet.settled);
}
