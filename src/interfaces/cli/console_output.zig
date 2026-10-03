//! The live stdout sink for `--console`, separate from the end-of-run report.
const std = @import("std");
const sci_line = @import("../../periph/sci/sci_line.zig");

/// Keep transcript lines visibly distinct from report sections.
pub fn configure(line: *sci_line.Line) void {
    line.setSink(.{ .writeFn = writeLine });
}

fn writeLine(_: ?*anyopaque, text: []const u8) anyerror!void {
    var out = std.io.getStdOut().writer();
    try out.writeAll("console> ");
    try out.writeAll(text);
    try out.writeAll("\n");
}
