//! Source lines to addresses: where `break fw.zig:8` should go.
//!
//! The reverse of src/session/dwarf/line/line.zig's lookup. Every unit's rows are
//! read, and the lowest address of a row on the asked line wins. A line
//! with no code of its own falls through to the nearest later line that
//! has some, which is where gdb puts a break on a blank or comment line.
const dwarf_line = @import("line.zig");
const line_header = @import("header.zig");

pub const Error = dwarf_line.Error;

pub const named = @import("path.zig").named;
pub const absolute = @import("path.zig").absolute;

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
        const directory = @import("../compilation.zig").directory(sections.units, offset) catch "";
        const unit = try line_header.read(sections.line, offset);
        offset = unit.end;
        try scan(unit.header, sections.strings, directory, file, line, &best);
    }
    return if (best) |found| found.address else null;
}

fn scan(header: dwarf_line.Header, strings: line_header.Strings, directory: []const u8, file: []const u8, line: u32, best: *?Best) Error!void {
    var rows = dwarf_line.Rows.init(header);
    while (try rows.next()) |row| {
        if (row.end_sequence or row.line < line) continue;
        if (!Best.better(best.*, row.line, row.address)) continue;
        var candidate = try line_header.file(header, row.file, strings);
        candidate.compilation_directory = directory;
        if (!named(candidate, file)) continue;
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
