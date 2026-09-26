//! The analog part of the end-of-run report, both directions of it.
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

/// The converter. A scan that ran is one line; a start the block refused and
/// a result firmware tried to write itself are separate, because each is a
/// bug a bench run would show and neither belongs folded into the traffic
/// that worked.
pub fn converter(board: *Board, out: Writer) !void {
    const unit = &board.adc;
    if (unit.quiet()) return;
    if (unit.scans != 0) {
        try out.print(
            "ADC_B: {d} scan(s), {d} channel(s) converted, last code {d} (0x{X:0>4})\n",
            .{ unit.scans, unit.converted, unit.last_code, unit.last_code },
        );
    }
    if (unit.refused_disabled != 0) {
        try out.print(
            "ADC_B: REFUSED {d} start(s) on a scan group ADSGER never enabled\n",
            .{unit.refused_disabled},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "ADC_B: REFUSED {d} store(s) into a result or status register\n",
            .{unit.faked},
        );
    }
    if (unit.empty != 0) {
        try out.print(
            "ADC_B: {d} scan(s) found no channel enrolled in the group\n",
            .{unit.empty},
        );
    }
    if (unit.unbacked != 0) {
        try out.print(
            "ADC_B: {d} converted channel(s) had no result register behind them\n",
            .{unit.unbacked},
        );
    }
    if (unit.stops != 0) {
        try out.print("ADC_B: {d} force-stop(s) through ADSTOPR\n", .{unit.stops});
    }
}
