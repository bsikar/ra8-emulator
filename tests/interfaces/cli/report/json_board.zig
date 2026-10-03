//! A board attached to an engine, for the `--report json` tests. Some
//! blocks (the DMAC among them) are only built by attach(), exactly as in a
//! real run, so a bare Board.init() is not a board the report can read.
const std = @import("std");
const ra8 = @import("ra8");

pub const Fixture = struct {
    core: ra8.core.engine.Engine,
    board: ra8.board.Board,

    /// Open in place: the board keeps pointers into itself once attached.
    pub fn open(self: *Fixture) !void {
        self.core = try ra8.core.engine.Engine.open();
        errdefer self.core.close();
        try self.core.mapBoardRam();
        self.board = ra8.board.Board.init(std.testing.allocator);
        errdefer self.board.deinit();
        try self.board.attach(&self.core);
    }

    pub fn close(self: *Fixture) void {
        self.board.deinit();
        self.core.close();
    }
};
