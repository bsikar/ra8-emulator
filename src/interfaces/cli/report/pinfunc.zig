//! The pin-routing part of the end-of-run report: how many pins the firmware
//! actually programmed, and every write the protect gate turned away.
//!
//! A refused pin write is the quiet one. It does not fault and the driver
//! never learns of it, so the run has to say it out loud or the bring-up bug
//! looks like a dead peripheral rather than a missing unlock.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;

pub fn sections(board: *Board, out: Writer) !void {
    const unit = &board.pinfunc;
    if (unit.quiet() and board.pins.direction_refused == 0) return;
    try out.print("PFS: {d} pin function write(s) landed\n", .{unit.programmed});
    if (unit.direction_refused != 0) {
        try out.print("PFS: REFUSED direction in {d} write(s), unsupported by the pad\n", .{unit.direction_refused});
    }
    if (board.pins.direction_refused != 0) {
        try out.print("GPIO: REFUSED direction in {d} write(s), unsupported by the pad\n", .{board.pins.direction_refused});
    }
    if (unit.guard.refused != 0) {
        try out.print(
            "PFS: REFUSED {d} pin function write(s), PWPRS.PFSWE was never set\n",
            .{unit.guard.refused},
        );
    }
    if (unit.ordering.glitched != 0) {
        try out.print(
            "PFS: {d} pin(s) handed straight from one peripheral function to another, " ++
                "clear PMR before programming a new PSEL\n",
            .{unit.ordering.glitched},
        );
    }
    if (unit.guard.ignored_keys != 0) {
        try out.print(
            "PFS: IGNORED {d} store(s) asking for PFSWE while B0WI still stood\n",
            .{unit.guard.ignored_keys},
        );
    }
}
