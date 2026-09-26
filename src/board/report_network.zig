//! The network part of the end-of-run report: the frames a CAN controller
//! actually put on its internal loopback and the ones it only wrote down,
//! where the Ethernet PTP timers got to, and what the AT modem on the
//! MikroBUS UART was asked.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;
const modem_line = @import("../periph/modem.zig");
const pi4ioe = @import("../periph/riic_pi4ioe.zig");
const ov5640 = @import("../periph/riic_ov5640.zig");

/// One block per controller that saw traffic. A transmit made out of
/// operation mode moves nothing on silicon, and a delivery with no receive
/// stage free is a frame the reader never sees, so both are reported apart
/// from the frames that landed.
pub fn sections(board: *Board, out: Writer) !void {
    try can(board, out);
    try ptp(board, out);
    try modem(board, out);
    try i2c(board, out);
}

/// One line per RIIC channel that saw traffic, then a line for each part on
/// the bus. A transfer clocked with the interface still disabled, a START on
/// a bus that was already busy, a byte written with no transaction open and a
/// read past what the device had to say are all things dev answered anyway,
/// so each is reported apart from the transfers that completed.
fn i2c(board: *Board, out: Writer) !void {
    const unit = &board.wire.controller;
    if (board.wire.quiet()) return;
    for (&unit.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "RIIC{d}: {d} transfer(s), {d} byte(s) out, {d} byte(s) in, {d} address(es) NACKed",
            .{ index, channel.transfers, channel.sent, channel.received, channel.nacks },
        );
        if (channel.uninit != 0) {
            try out.print(", {d} ACCESS(ES) WITH THE INTERFACE DISABLED", .{channel.uninit});
        }
        if (channel.st_busy != 0) {
            try out.print(", {d} START(S) ON A BUSY BUS REFUSED", .{channel.st_busy});
        }
        if (channel.rs_idle != 0) {
            try out.print(", {d} REPEATED START(S) WITH NOTHING TO REPEAT", .{channel.rs_idle});
        }
        if (channel.no_start != 0) {
            try out.print(", {d} DATA WRITE(S) WITH NO TRANSACTION OPEN", .{channel.no_start});
        }
        if (channel.overread != 0) {
            try out.print(", {d} READ(S) PAST WHAT THE DEVICE HAD TO SAY", .{channel.overread});
        }
        try out.print("\n", .{});
        if (channel.target.cycles != 0 or channel.target.unaddressed != 0) {
            try out.print(
                "RIIC{d} target: own 0x{X:0>2}, {d} controller write+read cycle(s), echo {s}",
                .{
                    index,
                    @as(u8, channel.target.own_address),
                    channel.target.cycles,
                    if (channel.target.mismatched) "MISMATCHED" else "matched",
                },
            );
            if (channel.target.unaddressed != 0) {
                try out.print(", {d} ARMING(S) WITH NO OWN ADDRESS REFUSED", .{channel.target.unaddressed});
            }
            try out.print("\n", .{});
        }
    }
    try expander(board, out);
    try camera(board, out);
}

/// The PI4IOE5V6408 port expander at 0x43.
fn expander(board: *Board, out: Writer) !void {
    const part = &board.wire.expander;
    if (part.quiet()) return;
    try out.print("I2C expander 0x{X:0>2}: {d} register write(s)", .{ @as(u8, pi4ioe.address), part.writes });
    if (part.bad_pointer != 0) {
        try out.print(", {d} POINTER(S) AT A REGISTER IT DOES NOT HAVE REFUSED", .{part.bad_pointer});
    }
    if (part.dropped != 0) {
        try out.print(", {d} payload byte(s) dropped with no register selected", .{part.dropped});
    }
    try out.print("\n", .{});
}

/// The camera's SCCB side at 0x3C.
fn camera(board: *Board, out: Writer) !void {
    const part = &board.wire.sensor;
    if (part.quiet()) return;
    try out.print(
        "I2C camera 0x{X:0>2}: {d} chip-id byte(s) read, {d} configuration write(s)",
        .{ @as(u8, ov5640.address), part.id_reads, part.writes },
    );
    if (part.unmodelled != 0) {
        try out.print(", {d} write(s) to a register this model does not carry", .{part.unmodelled});
    }
    try out.print("\n", .{});
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
    if (board.wire.quiet()) return;
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

/// What the modem answered, then the two ways a run can look answered and
/// not be: a line too long to be the command the driver sent, and a command
/// left on the line when the run ended.
fn modem(board: *Board, out: Writer) !void {
    const unit = &board.modem;
    if (board.wire.quiet()) return;
    try out.print(
        "AT modem: {d} command(s) answered, {d} refused with +CME ERROR\n",
        .{ unit.answered, unit.errors },
    );
    if (unit.overlong != 0) {
        try out.print(
            "AT modem: REFUSED {d} command line(s) longer than the modem accepts\n",
            .{unit.overlong},
        );
    }
    const left = unit.pending();
    if (left.len != 0) {
        try out.print("AT modem: \"{s}\" was left on the line, never terminated\n", .{left});
    }
    const channel = &board.serial.channels[modem_line.line_channel];
    if (channel.unheard != 0) {
        try out.print(
            "SCI{d}: {d} reply byte(s) LOST, the receiver was never enabled\n",
            .{ modem_line.line_channel, channel.unheard },
        );
    }
}
