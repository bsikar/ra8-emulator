//! The memory-controller part of the end-of-run report.
//!
//! On-chip SRAM is host memory here, so the only window onto the ECC path is
//! what the decoder self-test latched in SRAMESR and what it left in
//! SRAMEAR.
const std = @import("std");

const Board = @import("board.zig").Board;

const Writer = std.fs.File.Writer;

/// Quiet unless the run touched the ECC path. The refused store is the loud
/// case: SRAMESR is what the decoder found, so an image that wrote it was
/// claiming a caught fault it never injected.
pub fn sections(board: *Board, out: Writer) !void {
    const memory = &board.ecc;
    if (memory.quiet()) return;
    try out.print(
        "SRAM-ECC: {d} self-test latch(es), SRAMESR 0x{X:0>4}\n",
        .{ memory.latches, memory.esr },
    );
    if (memory.faked != 0) {
        try out.print(
            "SRAM-ECC: REFUSED {d} store(s) to SRAMESR, firmware cannot raise an ECC error flag itself\n",
            .{memory.faked},
        );
    }
}
