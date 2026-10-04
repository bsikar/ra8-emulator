//! Covers src/board/quiet_due.zig.
const std = @import("std");
const ra8 = @import("ra8");
const quiet_due = ra8.board.boundary.quiet_due;
const ulpt = ra8.periph.ulpt;

test "a fresh board is quiet until its next queued event" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(quiet_due.quietUntilDue(&board));
}

test "a running low-power timer keeps the board busy" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.lowpower.channels[1].cr |= ulpt.control.tstart;
    try std.testing.expect(!quiet_due.quietUntilDue(&board));
}

test "an armed transfer channel keeps the board busy" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.dma.channels[3].dmcnt |= ra8.periph.dmac.field.dte;
    try std.testing.expect(!quiet_due.quietUntilDue(&board));
}

test "the panel's next vsync is an edge ahead of now" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(quiet_due.vsyncDue(&board) > 0);
}
