//! Covers src/interfaces/cli/zig_run.zig: the board's side of a Zig-core
//! boundary.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const zig_run = ra8.board.zig_run;

test "a boundary is the chunk until SysTick is armed, then its period" {
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);
    var timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .core = &core, .board = &board, .timebase = &timebase };
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
    try core.writeWord(memmap.syst.rvr, 999);
    try core.writeWord(memmap.syst.csr, 0x7);
    try std.testing.expectEqual(@as(u32, 1000), clock.width());
    try core.writeWord(memmap.syst.rvr, 99_999);
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
}

test "closing a boundary charges the clocks and wraps SysTick into ICSR" {
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);
    var timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .core = &core, .board = &board, .timebase = &timebase };
    try clock.close(7);
    try std.testing.expectEqual(@as(u64, 7), timebase.elapsed);
    try core.writeWord(memmap.syst.rvr, 9);
    try core.writeWord(memmap.syst.cvr, 0);
    try core.writeWord(memmap.syst.csr, 0x7);
    try clock.close(10);
    try std.testing.expectEqual(@as(u64, 17), timebase.elapsed);
    try std.testing.expect(timebase.ticks > 0);
}
