//! Source lines to addresses: where `break fw.zig:8` should go.
//!
//! The reverse of src/session/dwarf/line/line.zig's lookup. Every unit's rows are
//! read, and the lowest address of a row on the asked line wins. A line
//! with no code of its own falls through to the nearest later line that
//! has some, which is where gdb puts a break on a blank or comment line.
const std = @import("std");
const dwarf_line = @import("line.zig");
const line_header = @import("header.zig");

pub const Error = dwarf_line.Error;

/// A file as written in a command: a bare name, a tail of its path, or
/// the whole path.
pub fn named(file: dwarf_line.File, wanted: []const u8) bool {
    const windows = windowsPath(file.directory) or windowsPath(file.name) or windowsPath(wanted);
    if (equalPath(file.name, wanted, windows) or tailOf(file.name, wanted, windows)) return true;
    if (file.directory.len == 0 or absolute(file.name)) return false;
    const directory = std.mem.trimEnd(u8, file.directory, if (windows) "/\\" else "/");
    if (wanted.len <= directory.len) return false;
    return separator(wanted[directory.len], windows) and
        equalPath(wanted[0..directory.len], directory, windows) and
        equalPath(wanted[directory.len + 1 ..], file.name, windows);
}

/// DWARF paths are strings; recognize roots without host file operations.
pub fn absolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and separator(path[2], true);
}

fn windowsPath(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '\\') != null or
        (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') or
        std.mem.startsWith(u8, path, "//");
}

fn separator(byte: u8, windows: bool) bool {
    return byte == '/' or (windows and byte == '\\');
}

fn equalPath(a: []const u8, b: []const u8, windows: bool) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (separator(left, windows) and separator(right, windows)) continue;
        if (windows) {
            if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
        } else if (left != right) return false;
    }
    return true;
}

fn tailOf(path: []const u8, wanted: []const u8, windows: bool) bool {
    if (path.len <= wanted.len) return false;
    return separator(path[path.len - wanted.len - 1], windows) and
        equalPath(path[path.len - wanted.len ..], wanted, windows);
}

/// The best row so far: its line, then its address, lowest first.
const Best = struct {
    line: u32,
    address: u32,

    fn better(self: ?Best, line: u32, address: u32) bool {
        const best = self orelse return true;
        if (line != best.line) return line < best.line;
        return address < best.address;
    }
};

/// The address a break on `file`:`line` goes at, or null when no row on
/// that line or after it in that file has code.
pub fn addressOf(sections: dwarf_line.Sections, file: []const u8, line: u32) Error!?u32 {
    var best: ?Best = null;
    var offset: usize = 0;
    while (offset < sections.line.len) {
        const unit = try line_header.read(sections.line, offset);
        offset = unit.end;
        try scan(unit.header, sections.strings, file, line, &best);
    }
    return if (best) |found| found.address else null;
}

fn scan(header: dwarf_line.Header, strings: line_header.Strings, file: []const u8, line: u32, best: *?Best) Error!void {
    var rows = dwarf_line.Rows.init(header);
    while (try rows.next()) |row| {
        if (row.end_sequence or row.line < line) continue;
        if (!Best.better(best.*, row.line, row.address)) continue;
        if (!named(try line_header.file(header, row.file, strings), file)) continue;
        best.* = .{ .line = row.line, .address = row.address };
    }
}

/// The lowest address in [low, high) that a row marks prologue_end, or
/// null when no row in that range carries the mark.
pub fn prologueEnd(sections: dwarf_line.Sections, low: u32, high: u32) Error!?u32 {
    var best: ?u32 = null;
    var offset: usize = 0;
    while (offset < sections.line.len) {
        const unit = try line_header.read(sections.line, offset);
        offset = unit.end;
        var rows = dwarf_line.Rows.init(unit.header);
        while (try rows.next()) |row| {
            if (row.end_sequence or !row.prologue_end) continue;
            if (row.address < low or row.address >= high) continue;
            if (best == null or row.address < best.?) best = row.address;
        }
    }
    return best;
}
