//! The SCI part of the end-of-run report: what each channel moved, and the
//! console line the firmware printed through it. Split out of report.zig,
//! which was at the file-length limit.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// One line per SCI channel that moved bytes, plus the last console line the
/// firmware printed. A TDR write made with CCR0.TE clear never leaves the
/// transmitter on silicon, so those are reported apart from the bytes that
/// did go out.
pub fn sections(board: *Board, out: Writer) !void {
    if (board.serial.quiet()) return;
    for (&board.serial.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "SCI{d}: TX {d} bytes, RX {d} bytes, {d} dropped on a full queue",
            .{ index, channel.transmitted, channel.received, channel.rx.dropped },
        );
        if (channel.unsent != 0) {
            try out.print(", {d} WRITE(S) WITH TE CLEAR NEVER SENT", .{channel.unsent});
        }
        try out.print("\n", .{});
    }
    if (board.serial.line.lines != 0) {
        try out.print("SCI console: {d} line(s), last \"{s}\"\n", .{ board.serial.line.lines, board.serial.line.slice() });
    }
}

/// One line per SPI channel the firmware touched. A store made with SPE
/// clear never reaches a wire on silicon, and a read of an empty receive
/// holding register is a frame dev would have served twice.
pub fn spi(board: *Board, out: Writer) !void {
    for (&board.spi.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "SPI{d}: SPE={d}, {d} frame(s) clocked, last 0x{X:0>2}, loopback={s}\n",
            .{
                index,
                @intFromBool(unit.enabled()),
                unit.frames,
                unit.last,
                if (unit.loopback()) "on" else "off",
            },
        );
        if (unit.refused != 0) {
            try out.print(
                "SPI{d}: REFUSED {d} SPDR store(s) with SPE clear, the channel was never started\n",
                .{ index, unit.refused },
            );
        }
        if (unit.starved != 0) {
            try out.print(
                "SPI{d}: {d} SPDR read(s) with the receive register empty, no frame had arrived\n",
                .{ index, unit.starved },
            );
        }
    }
}

/// The RTT ring, once a firmware has published one. A run with no RTT user
/// says nothing here. The unfinished tail is reported rather than dropped:
/// text the firmware never ended with a newline is still text it wrote, and
/// a line this model cut short is counted apart from the lines it did end.
pub fn trace(board: *Board, out: Writer) !void {
    const probe = &board.trace;
    if (probe.quiet()) return;
    if (probe.found) |at| {
        try out.print(
            "SEGGER RTT: control block @0x{X:0>8}, {d} byte(s) drained, {d} line(s)\n",
            .{ at, probe.drained, probe.line.lines },
        );
    } else {
        try out.print(
            "SEGGER RTT: no live control block, {d} byte(s) drained, {d} line(s)\n",
            .{ probe.drained, probe.line.lines },
        );
    }
    if (probe.line.lines != 0) {
        try out.print("SEGGER RTT: last \"{s}\"\n", .{probe.line.slice()});
    }
    if (probe.line.pending().len != 0) {
        try out.print(
            "SEGGER RTT: {d} byte(s) drained with no newline behind them, \"{s}\"\n",
            .{ probe.line.pending().len, probe.line.pending() },
        );
    }
    if (probe.line.wrapped != 0) {
        try out.print(
            "SEGGER RTT: {d} line(s) CUT at {d} characters, the firmware never ended them\n",
            .{ probe.line.wrapped, @as(u32, @intCast(probe.line.pending().len + probe.line.slice().len)) },
        );
    }
    if (probe.off_ram != 0) {
        try out.print(
            "SEGGER RTT: REFUSED {d} control block(s) whose ring was not in RAM\n",
            .{probe.off_ram},
        );
    }
    if (probe.forgotten != 0) {
        try out.print(
            "SEGGER RTT: {d} block(s) went away mid-run and the scan was re-armed\n",
            .{probe.forgotten},
        );
    }
}
