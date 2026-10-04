//! The live stdout sink for `--console`, separate from the end-of-run report,
//! and the tap `--until` reads finished lines from.
const std = @import("std");
const sci_line = @import("../../periph/sci/sci_line.zig");
const until = @import("../../core/until.zig");
const sci_reply = @import("../../periph/sci/sci_reply.zig");

/// Where each finished console line goes: stdout when `--console` asked
/// for it, and the `--until` wait when one is set.
pub const Tap = struct {
    echo: bool = false,
    wait: ?until.Until = null,
    /// The `--console-reply` that watches for its prompt (RA8EMU-626).
    reply: ?*sci_reply.Reply = null,

    /// Whether the line needs a sink at all.
    pub fn wanted(self: Tap) bool {
        return self.echo or self.wait != null or self.reply != null;
    }

    /// The `--until` wait the run loop checks, held here so it lives as
    /// long as the sink that feeds it.
    pub fn waiting(self: *Tap) ?*until.Until {
        return if (self.wait) |*one| one else null;
    }
};

/// Hang the tap on the console line. The tap has to outlive the run.
pub fn configure(line: *sci_line.Line, tap: *Tap) void {
    if (tap.wanted()) line.setSink(.{ .context = tap, .writeFn = tapLine });
}

/// Hand one finished line to the tap.
pub fn tapLine(context: ?*anyopaque, text: []const u8) anyerror!void {
    const tap: *Tap = @ptrCast(@alignCast(context.?));
    if (tap.waiting()) |wait| wait.line(text);
    if (tap.reply) |reply| reply.line(text);
    if (tap.echo) try writeLine(text);
}

/// Keep transcript lines visibly distinct from report sections.
fn writeLine(text: []const u8) anyerror!void {
    var out = std.io.getStdOut().writer();
    try out.writeAll("console> ");
    try out.writeAll(text);
    try out.writeAll("\n");
}
