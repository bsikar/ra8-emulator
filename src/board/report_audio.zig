//! The audio part of the end-of-run report.
//!
//! There is no audio clock in the model, so what a run says about SSIE is the
//! handshake and the sample stream: whether the transmitter was actually on,
//! how many samples went out behind it, and what the transmit FIFO was still
//! holding when the run ended.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// One line per channel the firmware touched, plus the two loud cases. A
/// sample staged with TEN clear is one dev counts as transmitted, and a store
/// past the last FIFO stage is one dev never notices at all.
pub fn sections(board: *Board, out: Writer) !void {
    for (&board.audio.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "SSIE{d}: TEN={d} REN={d}, {d} sample(s) transmitted, last 0x{X:0>8}\n",
            .{
                index,
                @intFromBool(unit.transmitting()),
                @intFromBool(unit.ssicr & 1 != 0),
                unit.transmitted,
                unit.last,
            },
        );
        if (unit.staged != 0) {
            try out.print(
                "SSIE{d}: {d} sample(s) left in the transmit FIFO with TEN clear, never shifted out\n",
                .{ index, unit.staged },
            );
        }
        if (unit.dropped != 0) {
            try out.print(
                "SSIE{d}: {d} sample(s) DROPPED on a full transmit FIFO\n",
                .{ index, unit.dropped },
            );
        }
    }
}
