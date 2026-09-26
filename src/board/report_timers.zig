//! The timer part of the end-of-run report: which channels actually counted,
//! and the writes a running channel refused. All three timer families live
//! here: the low-power timer that counts through standby, the interval
//! timers, and the PWM timers.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// AGT first, then GPT, the order dev's combined report used. A channel that
/// never ran and never counted anything says nothing.
pub fn sections(board: *Board, out: Writer) !void {
    try lowpower(board, out);
    try interval(board, out);
    try pwm(board, out);
}

fn lowpower(board: *Board, out: Writer) !void {
    const unit = &board.lowpower;
    if (unit.quiet()) return;
    for (&unit.channels, 0..) |*channel, index| {
        if (channel.underflows == 0 and !channel.running()) continue;
        try out.print(
            "ULPT{d}: counter 0x{X:0>8}, {d} underflow(s), divide by {d}, {s}\n",
            .{
                index,
                channel.counter,
                channel.underflows,
                channel.divider(),
                if (channel.running()) "running" else "stopped",
            },
        );
        if (channel.forced_stops != 0) {
            try out.print("ULPT{d}: {d} forced stop(s) through TSTOP\n", .{ index, channel.forced_stops });
        }
    }
    if (unit.compare_touches != 0) {
        try out.print(
            "ULPT: {d} COMPARE-MATCH ACCESS(ES), NOT MODELLED (ULPTCMA/CMB are stored and never compared, so no compare event is raised)\n",
            .{unit.compare_touches},
        );
    }
}

/// PRCR and the domain it protects. Both stay quiet when the firmware never
/// touched them, and both go loud when a write was dropped: on silicon those
/// writes vanish with no fault and no flag, which is the failure that is
/// impossible to spot from the firmware side.
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
