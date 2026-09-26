//! The timer part of the end-of-run report: which channels actually counted,
//! and the writes a running channel refused.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// AGT first, then GPT, the order dev's combined report used. A channel that
/// never ran and never counted anything says nothing.
pub fn sections(board: *Board, out: Writer) !void {
    try interval(board, out);
    try pwm(board, out);
}

fn interval(board: *Board, out: Writer) !void {
    for (&board.interval.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "AGT{d}: count 0x{X:0>4} of 0x{X:0>4}, {d} underflow(s), running={s}\n",
            .{ index, channel.counter, channel.reload, channel.underflows, yesno(channel.running()) },
        );
        if (channel.matches_a != 0 or channel.matches_b != 0) {
            try out.print(
                "AGT{d}: compare match A {d} time(s), B {d} time(s)\n",
                .{ index, channel.matches_a, channel.matches_b },
            );
        }
        if (channel.forced_stops != 0) {
            try out.print(
                "AGT{d}: {d} forced stop(s) through AGTCR.TSTOP\n",
                .{ index, channel.forced_stops },
            );
        }
        if (channel.refused_running != 0) {
            try out.print(
                "AGT{d}: REFUSED {d} counter/compare write(s) with the count running\n",
                .{ index, channel.refused_running },
            );
        }
    }
}

fn pwm(board: *Board, out: Writer) !void {
    for (&board.pwm.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "GPT{d}: GTCNT 0x{X:0>8} of 0x{X:0>8}, {d} overflow(s), running={s}\n",
            .{ index, channel.cnt, channel.periodOrDefault(), channel.overflows, yesno(channel.running()) },
        );
    }
}

fn yesno(value: bool) []const u8 {
    return if (value) "yes" else "no";
}
