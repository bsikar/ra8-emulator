//! The compute part of the end-of-run report: what the NPU was asked to do,
//! what it actually moved, and the kicks it refused to pretend about.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// One line per run that touched the NPU window, plus a line for each kind
/// of kick that produced no job. A stream dev would have run down the copy
/// path is reported here as the unknown opcode it carries, so an image
/// cannot collect a completed job it never earned.
pub fn sections(board: *Board, out: Writer) !void {
    const unit = &board.npu;
    if (unit.quiet()) return;
    if (unit.jobs == 0 and unit.faults() == 0) {
        try out.print(
            "NPU(Ethos-U55): window touched, {d} read(s), {d} write(s), no job kicked\n",
            .{ unit.reads, unit.writes },
        );
        return;
    }
    try out.print(
        "NPU(Ethos-U55): {d} job(s), {d} byte(s) moved, last {s} {d}B check=0x{X:0>8}" ++
            " (stand-in, not Vela)\n",
        .{
            unit.jobs,
            unit.moved,
            if (unit.last_op) |op| op.label() else "none",
            unit.last_bytes,
            unit.last_check,
        },
    );
    if (unit.unknown_ops != 0) {
        try out.print(
            "NPU(Ethos-U55): REFUSED {d} stream(s) carrying an opcode this model does not run\n",
            .{unit.unknown_ops},
        );
    }
    if (unit.malformed != 0) {
        try out.print(
            "NPU(Ethos-U55): REFUSED {d} stream(s) that do not describe a job\n",
            .{unit.malformed},
        );
    }
    if (unit.unmapped_region != 0) {
        try out.print(
            "NPU(Ethos-U55): REFUSED {d} kick(s) naming a region with no base programmed\n",
            .{unit.unmapped_region},
        );
    }
    if (unit.unreachable_memory != 0) {
        try out.print(
            "NPU(Ethos-U55): {d} kick(s) FAULTED, the stream or an arena could not be reached\n",
            .{unit.unreachable_memory},
        );
    }
    if (unit.in_place != 0) {
        try out.print(
            "NPU(Ethos-U55): {d} job(s) ran a region onto itself, nothing observable moved\n",
            .{unit.in_place},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "NPU(Ethos-U55): REFUSED {d} store(s) to ID or STATUS\n",
            .{unit.faked},
        );
    }
}
