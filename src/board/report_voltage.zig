//! The end-of-run lines for the core voltage range.
const Board = @import("board.zig").Board;

pub fn sections(board: *const Board, out: anytype) !void {
    const unit = &board.voltage;
    if (unit.quiet()) return;

    if (unit.stores != 0) {
        try out.print("core voltage: {s} range selected\n", .{unit.range().name()});
    }
    if (unit.transitions > 1) {
        try out.print("core voltage: {d} range change(s)\n", .{unit.transitions});
    }
    if (unit.dropped_locked != 0) {
        try out.print("core voltage: DROPPED {d} store(s), PRCR.PRC0 was locked\n", .{unit.dropped_locked});
    }
    if (unit.flag_writes != 0) {
        try out.print("core voltage: {d} store(s) named VSCMTSF, which only hardware sets\n", .{unit.flag_writes});
    }
}
