//! What a session prints about source: the file and line an address
//! belongs to, read from the image's DWARF line table.
//!
//! The wording follows gdb's `info line`, so a transcript reads the same
//! either way. An image without line information, or a table this reader
//! refuses, answers the way gdb does for an address it has no line for.
const std = @import("std");
const elf = @import("../core/elf.zig");
const dwarf_line = @import("dwarf_line.zig");
const dwarf_line_find = @import("dwarf_line_find.zig");

/// The line sections of the session's image, empty when there is none.
pub fn of(image: ?elf.Image) dwarf_line.Sections {
    return if (image) |loaded| dwarf_line.ofImage(loaded) else .{};
}

/// `info line`: the line `address` belongs to and the addresses it covers.
pub fn line(out: anytype, sections: dwarf_line.Sections, address: u32) !void {
    const found = dwarf_line.lookup(sections, address) catch null;
    const place = found orelse {
        return out.print("No line number information available for address 0x{X:0>8}\n", .{address});
    };
    try out.print("Line {d} of \"", .{place.line});
    try path(out, place.file);
    try out.print("\" starts at address 0x{X:0>8} and ends at 0x{X:0>8}.\n", .{ place.address, place.end });
}

/// A file's name, under its directory unless the name is already absolute.
pub fn path(out: anytype, file: dwarf_line.File) !void {
    const absolute = std.mem.startsWith(u8, file.name, "/");
    if (file.directory.len != 0 and !absolute) try out.print("{s}/", .{file.directory});
    try out.print("{s}", .{file.name});
}

/// A place spelled FILE:LINE, as `break fw.zig:8` takes it.
pub const FileLine = struct {
    file: []const u8,
    line: u32,
};

/// FILE:LINE, or null when the text is some other kind of place.
pub fn fileLine(text: []const u8) ?FileLine {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    if (colon == 0) return null;
    const number = std.fmt.parseInt(u32, text[colon + 1 ..], 10) catch return null;
    if (number == 0) return null;
    return .{ .file = text[0..colon], .line = number };
}

/// Where a break on FILE:LINE goes, or null when the line table has no
/// code there or after it in that file.
pub fn breakAt(sections: dwarf_line.Sections, want: FileLine) ?u32 {
    return dwarf_line_find.addressOf(sections, want.file, want.line) catch null;
}
