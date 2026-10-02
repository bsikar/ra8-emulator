//! A debugger script: lines of the command language, played into a session.
//!
//! A script is how a debugging session becomes reproducible. Each line is
//! parsed and applied in turn, and with `echo` on each command is printed
//! behind the prompt first, so the transcript reads the way the session
//! would have looked typed by hand and diffs cleanly against a checked-in
//! copy. A line that does not parse prints `error: <why>` and the script
//! carries on, the same as a command that parses but cannot be carried out.
const std = @import("std");
const commands = @import("commands.zig");
const session = @import("session.zig");

/// What the debugger prints before each command it reads or echoes.
pub const prompt = "(ra8) ";

/// Play every line of `text` into `target`, stopping early at `quit`.
pub fn play(target: *session.Session, text: []const u8, out: anytype, echo: bool) !session.Outcome {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (try one(target, line, out, echo) == .quit) return .quit;
    }
    return .more;
}

/// Parse and apply a single line. A blank or comment-only line does nothing
/// and is not echoed.
pub fn one(target: *session.Session, line: []const u8, out: anytype, echo: bool) !session.Outcome {
    const parsed = commands.parse(line) catch |err| {
        if (echo) try out.print("{s}{s}\n", .{ prompt, std.mem.trim(u8, line, " \t\r") });
        try out.print("error: {s}\n", .{@errorName(err)});
        return .more;
    };
    const command = parsed orelse return .more;
    if (echo) try out.print("{s}{s}\n", .{ prompt, std.mem.trim(u8, line, " \t\r") });
    return target.apply(command, out);
}
