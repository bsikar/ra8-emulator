//! The board's boundary as the debugger's run passes it (RA8EMU-709).
//! Board.tick wants the guest events are pended on; under the debugger
//! that is CPU0's memory, the same guest a plain run ticks with. CPU1's
//! lines are re-pended by the boundary itself (events.rependOn).
const Board = @import("board.zig").Board;
const Guest = @import("../core/cpu/memory/guest.zig").Guest;
const zig_boundary = @import("../debug/zig_boundary.zig");

pub const BoardBoundary = struct {
    board: *Board,
    core: Guest,

    pub fn hook(self: *BoardBoundary) zig_boundary.Boundary {
        return .{ .context = self, .tickFn = tick };
    }

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *BoardBoundary = @ptrCast(@alignCast(context));
        try self.board.tick(self.core, instructions);
    }
};
