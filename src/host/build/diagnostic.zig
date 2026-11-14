//! Zig's file:line:column diagnostics, independent of terminal styling.
const std = @import("std");
pub const Diagnostic = struct { path: []const u8, line: u32, column: u32, message: []const u8 };

pub fn parse(text: []const u8) ?Diagnostic {
    var colons = std.mem.splitScalar(u8, text, ':');
    while (colons.next()) |_| {
        const first = colons.index orelse return null;
        const line_end = std.mem.indexOfScalarPos(u8, text, first, ':') orelse return null;
        const column_end = std.mem.indexOfScalarPos(u8, text, line_end + 1, ':') orelse return null;
        const line = std.fmt.parseInt(u32, text[first..line_end], 10) catch continue;
        const column = std.fmt.parseInt(u32, text[line_end + 1 .. column_end], 10) catch continue;
        if (first <= 1 or line == 0 or column == 0) return null;
        return .{ .path = text[0 .. first - 1], .line = line, .column = column, .message = std.mem.trim(u8, text[column_end + 1 ..], " \r\n") };
    }
    return null;
}
