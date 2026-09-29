//! The end-of-run lines for PLL1's configuration registers.
const std = @import("std");
const Board = @import("board.zig").Board;

fn ratio(value: ?u8, out: anytype) !void {
    if (value) |one| {
        try out.print("/{d}", .{one});
    } else {
        try out.print("/?", .{});
    }
}

pub fn sections(board: *const Board, out: anytype) !void {
    const unit = &board.pll1;
    if (unit.quiet()) return;

    if (unit.configured()) {
        const mul = unit.multiplier();
        try out.print("PLL1: {s} in ", .{unit.source().name()});
        try ratio(unit.inputRatio(), out);
        try out.print(", x{d}.{d:0>2}, P", .{ mul.whole(), mul.hundredths() });
        const outputs = unit.outputRatios();
        try ratio(outputs[0], out);
        try out.print(" Q", .{});
        try ratio(outputs[1], out);
        try out.print(" R", .{});
        try ratio(outputs[2], out);
        try out.print("\n", .{});
    }
    if (unit.moscwtcr != 0) {
        try out.print("PLL1: main oscillator wait code {d}\n", .{unit.moscwtcr});
    }
    if (unit.dropped_locked != 0) {
        try out.print("PLL1: DROPPED {d} store(s), PRCR.PRC0 was locked\n", .{unit.dropped_locked});
    }
    if (unit.prohibited_divider != 0) {
        try out.print("PLL1: REJECTED {d} PLLCCR2 store(s) carrying a prohibited divider code\n", .{unit.prohibited_divider});
    }
}
