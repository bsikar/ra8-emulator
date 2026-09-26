//! The option-setting part of the end-of-run report: what the extra-MRAM
//! sequencer actually programmed, and every command it refused.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// One line per run that issued a MACI command. A refused command is
/// reported apart from the work that landed: on silicon each of these
/// leaves the option memory untouched, and dev ran every one of them.
pub fn sections(board: *Board, out: Writer) !void {
    const unit = &board.options;
    if (unit.quiet()) return;
    try out.print(
        "Extra-MRAM: {d} program(s), {d} config set(s), {d} option cell(s) holding data\n",
        .{ unit.programs, unit.config_sets, unit.otp.live() },
    );
    if (unit.illegal != 0) {
        try out.print(
            "Extra-MRAM: REJECTED {d} command(s) aimed outside the option-setting window, sequencer command-locked\n",
            .{unit.illegal},
        );
    }
    if (unit.locked_out != 0) {
        try out.print(
            "Extra-MRAM: REFUSED {d} command(s) while command-locked, only leaving program mode releases it\n",
            .{unit.locked_out},
        );
    }
    if (unit.outside_mode != 0) {
        try out.print(
            "Extra-MRAM: REFUSED {d} command(s) with program/erase mode never entered\n",
            .{unit.outside_mode},
        );
    }
    if (unit.malformed != 0) {
        try out.print(
            "Extra-MRAM: REFUSED {d} command(s) whose payload was not the length the opener declared\n",
            .{unit.malformed},
        );
    }
    if (unit.rewrites != 0) {
        try out.print(
            "Extra-MRAM: REFUSED {d} program(s) asking a one-time-programmable cell for a bit back\n",
            .{unit.rewrites},
        );
    }
    if (unit.keyless != 0) {
        try out.print("Extra-MRAM: REFUSED {d} MENTRYR write(s) carrying the wrong key\n", .{unit.keyless});
    }
    if (unit.read_only != 0) {
        try out.print(
            "Extra-MRAM: REFUSED {d} store(s) to MSTATR/MASTAT, firmware cannot clear its own errors\n",
            .{unit.read_only},
        );
    }
    if (unit.faulted != 0) {
        try out.print("Extra-MRAM: {d} program(s) LOST, the option window refused the write\n", .{unit.faulted});
    }
}
