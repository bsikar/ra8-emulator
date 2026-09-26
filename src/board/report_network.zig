//! The network part of the end-of-run report: the frames a CAN controller
//! actually put on its internal loopback and the ones it only wrote down,
//! then where the Ethernet PTP timers got to.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// One block per controller that saw traffic. A transmit made out of
/// operation mode moves nothing on silicon, and a delivery with no receive
/// stage free is a frame the reader never sees, so both are reported apart
/// from the frames that landed.
pub fn sections(board: *Board, out: Writer) !void {
    try can(board, out);
    try ptp(board, out);
}

/// One block per CAN controller that saw traffic.
fn can(board: *Board, out: Writer) !void {
    for (&board.can.units, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "CANFD{d}: {d} frame(s) transmitted, {d} received, {d} waiting in the FIFO\n",
            .{ index, unit.sent, unit.received, unit.queue.len() },
        );
        if (unit.refused != 0) {
            try out.print(
                "CANFD{d}: REFUSED {d} transmit(s) out of operation mode, the channel was never started\n",
                .{ index, unit.refused },
            );
        }
        if (unit.filtered != 0) {
            try out.print(
                "CANFD{d}: {d} frame(s) dropped by the acceptance filter\n",
                .{ index, unit.filtered },
            );
        }
        if (unit.lost != 0) {
            try out.print("CANFD{d}: {d} frame(s) LOST, no receive stage free\n", .{ index, unit.lost });
        }
        if (unit.starved != 0) {
            try out.print("CANFD{d}: {d} pop(s) of an empty receive FIFO\n", .{ index, unit.starved });
        }
        if (unit.faked != 0) {
            try out.print(
                "CANFD{d}: REFUSED {d} store(s) into a status register the controller owns\n",
                .{ index, unit.faked },
            );
        }
    }
    if (board.can.wakes != 0) {
        try out.print("CANFD0: {d} receive event(s) raised\n", .{board.can.wakes});
    }
}

/// One line per PTP timer unit that ran, then the things firmware got
/// wrong. A store into a register the timer owns and an offset that was
/// not a time are both bench-visible bugs, so they are reported apart from
/// the time that was actually kept.
fn ptp(board: *Board, out: Writer) !void {
    const unit = &board.ptp;
    if (unit.quiet()) return;
    for (&unit.units, 0..) |*timer, index| {
        if (!timer.ran()) continue;
        const now = timer.now();
        try out.print(
            "GPTP timer{d}: {d}.{d:0>9} s after {d} boundaries, {s}\n",
            .{ index, now.sec, now.nsec, timer.ticks, if (timer.enabled) "running" else "stopped" },
        );
    }
    if (unit.unknown_unit != 0) {
        try out.print(
            "GPTP: {d} enable bit(s) naming a timer this part does not have\n",
            .{unit.unknown_unit},
        );
    }
    if (unit.denormal != 0) {
        try out.print(
            "GPTP: {d} offset(s) carried, the nanoseconds field held a second or more\n",
            .{unit.denormal},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "GPTP: REFUSED {d} store(s) into a monitoring register the timer owns\n",
            .{unit.faked},
        );
    }
    if (unit.read_only != 0) {
        try out.print("GPTP: REFUSED {d} store(s) into PTPIPV, which is read-only\n", .{unit.read_only});
    }
}
