//! The D/A part of the end-of-run report.
//!
//! DAC_B has no conversion-result readback on this part, so a headless run's
//! only window onto the channel is the code stream firmware wrote and whether
//! DACR0.DACEN was set when it wrote it.
const std = @import("std");

const Board = @import("board.zig").Board;

const Writer = std.fs.File.Writer;

/// One line per channel the firmware moved. The dark count is the loud case:
/// a code stored with DACEN clear latches but converts nothing, so an image
/// whose enable never took looks identical to a working one on dev, which
/// counts every store as an output.
pub fn sections(board: *Board, out: Writer) !void {
    for (&board.analog.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "DAC_B{d}: {d} output(s), last {d}, peak {d}, channel {s}\n",
            .{
                index,
                unit.outputs,
                unit.code,
                unit.peak,
                if (unit.enabled()) "enabled" else "disabled",
            },
        );
        if (unit.dark != 0) {
            try out.print(
                "DAC_B{d}: {d} code(s) written with DACEN clear, latched but not converted\n",
                .{ index, unit.dark },
            );
        }
    }
}
