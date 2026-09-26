//! The storage part of the end-of-run report: what the firmware did to the
//! octal NOR flash, and the commands the engine refused.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// One line per run that touched the flash. A program or erase that arrived
/// with the write-enable latch clear does nothing on silicon, and a
/// descriptor asking for more than slot 0 holds is a driver bug dev would
/// have run anyway, so both are reported apart from the work that landed.
pub fn sections(board: *Board, out: Writer) !void {
    const unit = &board.flash;
    if (unit.quiet()) return;
    try out.print(
        "XSPI flash: {d} read(s), {d} program(s), {d} erase(s), {d} sector(s) holding data\n",
        .{ unit.reads, unit.programs, unit.erases, unit.flash.live() },
    );
    if (unit.unarmed != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} program/erase(s) with the write-enable latch clear\n",
            .{unit.unarmed},
        );
    }
    if (unit.oversized != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} descriptor(s) asking for more than the 8 bytes slot 0 holds\n",
            .{unit.oversized},
        );
    }
    if (unit.out_of_part != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} command(s) running off the end of the part\n",
            .{unit.out_of_part},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} store(s) to INTS, firmware cannot raise a completion itself\n",
            .{unit.faked},
        );
    }
    if (unit.lost != 0) {
        try out.print("XSPI flash: {d} program(s) LOST, no room to hold the sector\n", .{unit.lost});
    }
}
