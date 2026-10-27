//! The display's advance: run CPU0 until the board's time reaches a deadline.
const std = @import("std");
const session_api = @import("../api.zig");
const Board = @import("ra8_board").board.Board;
const board_boundary = @import("../board/boundary.zig");

/// Runs CPU0 on `session` for `max_ns` of virtual time, whichever core the
/// session had selected, and puts that selection and the budget back.
pub fn run(session: *session_api.Session, board: *Board, edge: *board_boundary.BoardBoundary, max_ns: u64) anyerror!void {
    const selected = session.currentCore();
    try session.switchTo(.cpu0);
    defer session.switchTo(selected) catch {};
    const deadline = (try session.now()) +| max_ns;
    const budget = session.live.budget;
    defer session.live.budget = budget;
    while ((try session.now()) < deadline) {
        const remaining = board.time.base.cyclesUntil(deadline) -| edge.saved.stretch.carry;
        session.live.budget = @max(1, @min(budget, remaining));
        const before = try session.now();
        _ = try session.run(.cpu0, .cont);
        if ((try session.now()) <= before) return error.NoVirtualProgress;
    }
}
