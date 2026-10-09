//! The source pane (RA8EMU-745): the source lines around the line a core's
//! pc belongs to, read through the image's DWARF line table. Each row is a
//! gutter (a red square on a breakpoint, an amber '>' at the current line),
//! the line number and the text; the current line sits on a full-width band.
//! A click in the gutter sets or clears a breakpoint on that line.
//!
//! The session keeps neither the image nor where its sources live, so the
//! shell hands in the line sections, the image and the source directory.
//! Until the session can list a core's breakpoints (RA8EMU-765), `Marks`
//! remembers the ones this gutter set, with the ids that clear them.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const elf = @import("../../board/loader/elf.zig");
const dwarf_line = @import("../../session/dwarf_line.zig");
const session_api = @import("../../session/session_api.zig");
const session_source = @import("../../session/session_source.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const muted = Color.rgb(0x9A, 0xA5, 0xB4);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const current_band = Color.rgb(0x2F, 0x3B, 0x4C);
pub const current_ink = Color.rgb(0xE5, 0xC0, 0x7B);
pub const break_mark = Color.rgb(0xE0, 0x6C, 0x75);
pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const max_rows: usize = 48;
/// Characters of a source line a row keeps.
pub const text_cap: usize = 120;
pub const path_cap: usize = 256;
pub const max_marks: usize = 32;
/// Character columns: the gutter, the line number, the text.
pub const number_at: usize = 2;
pub const number_len: usize = 5;
pub const text_at: usize = number_at + number_len + 1;
/// The narrowest pane: the columns before the text and room for 16 more.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(text_at + 16)));

pub const Row = struct {
    number: u32 = 0,
    buf: [text_cap]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Row) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const State = enum { no_line, no_file, shown };

pub const Snapshot = struct {
    pc: u32 = 0,
    state: State = .no_line,
    path_buf: [path_cap]u8 = undefined,
    path_len: usize = 0,
    /// The line pc belongs to.
    current: u32 = 0,
    count: usize = 0,
    rows: [max_rows]Row = @splat(.{}),

    pub fn path(self: *const Snapshot) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// Reads `core`'s pc, finds its line in `sections`, and reads up to
/// `row_count` lines of that file from `dir`, the current one in the middle.
pub fn capture(session: *session_api.Session, core: session_api.Core, sections: dwarf_line.Sections, io: std.Io, dir: std.Io.Dir, row_count: usize) anyerror!Snapshot {
    var snapshot: Snapshot = .{ .pc = try session.register(core, .pc) };
    const place = (dwarf_line.lookup(sections, snapshot.pc) catch null) orelse return snapshot;
    var spelled: std.Io.Writer = .fixed(&snapshot.path_buf);
    session_source.path(&spelled, place.file) catch return snapshot;
    snapshot.path_len = spelled.buffered().len;
    snapshot.current = place.line;
    snapshot.state = .no_file;
    const file = dir.openFile(io, snapshot.path(), .{}) catch return snapshot;
    defer file.close(io);
    const wanted = @min(row_count, max_rows);
    const half: u32 = @intCast(wanted / 2);
    const first = if (place.line > half) place.line - half else 1;
    var staging: [4096]u8 = undefined;
    var reader = file.reader(io, &staging);
    try readRows(&snapshot, &reader.interface, first, wanted);
    snapshot.state = .shown;
    return snapshot;
}

fn readRows(snapshot: *Snapshot, reader: *std.Io.Reader, first: u32, wanted: usize) !void {
    var number: u32 = 1;
    while (snapshot.count < wanted) : (number += 1) {
        var row: Row = .{ .number = number };
        var held: std.Io.Writer = .fixed(&row.buf);
        const ended = try session_source.takeLine(reader, &held);
        row.len = held.buffered().len;
        if (ended and row.len == 0) return;
        if (number >= first) {
            std.mem.replaceScalar(u8, row.buf[0..row.len], '\t', ' ');
            snapshot.rows[snapshot.count] = row;
            snapshot.count += 1;
        }
        if (ended) return;
    }
}

/// Streams one line into `held`, at most its capacity, and drops the rest of
/// the line and its newline. True when the stream ended on this line.
pub const Mark = struct {
    file: u64,
    line: u32,
    id: session_api.BreakId,
};

/// The breakpoints this gutter set on one core.
pub const Marks = struct {
    items: [max_marks]Mark = undefined,
    len: usize = 0,

    pub fn find(self: *const Marks, file: []const u8, line: u32) ?usize {
        const key = std.hash.Fnv1a_64.hash(file);
        for (self.items[0..self.len], 0..) |mark, index| {
            if (mark.file == key and mark.line == line) return index;
        }
        return null;
    }
};

pub const Error = error{ NoCodeOnLine, TooManyMarks };

/// Clears the breakpoint the gutter set on `line` of `file`, or sets one
/// where the line table puts that line's code. True when one is now set.
pub fn toggle(marks: *Marks, session: *session_api.Session, core: session_api.Core, image: ?elf.Image, file: []const u8, line: u32) anyerror!bool {
    if (marks.find(file, line)) |index| {
        try session.clearBreakpoint(core, marks.items[index].id);
        marks.items[index] = marks.items[marks.len - 1];
        marks.len -= 1;
        return false;
    }
    if (marks.len == max_marks) return Error.TooManyMarks;
    const address = session_source.breakAt(image, .{ .file = file, .line = line }) orelse return Error.NoCodeOnLine;
    const id = try session.setBreakpoint(core, .{ .address = address });
    marks.items[marks.len] = .{ .file = std.hash.Fnv1a_64.hash(file), .line = line, .id = id };
    marks.len += 1;
    return true;
}

/// The line under a click at (`x`, `y`) when it lands in the gutter of a
/// shown row.
pub fn lineAt(area: Rect, snapshot: *const Snapshot, x: i32, y: i32) ?u32 {
    if (snapshot.state != .shown) return null;
    if (x < area.x or x >= area.x + pad + 2 + column(number_at)) return null;
    const top = area.y + pad;
    if (y < top) return null;
    const row: usize = @intCast(@divTrunc(y - top, row_h));
    if (row >= @min(rows(area), snapshot.count)) return null;
    return snapshot.rows[row].number;
}

/// A gutter click: toggles that line's breakpoint, or null when the click
/// missed the gutter.
pub fn click(marks: *Marks, session: *session_api.Session, core: session_api.Core, image: ?elf.Image, area: Rect, snapshot: *const Snapshot, x: i32, y: i32) anyerror!?bool {
    const line = lineAt(area, snapshot, x, y) orelse return null;
    return try toggle(marks, session, core, image, snapshot.path(), line);
}

/// How many rows fit down `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// Row `row`'s full-width band.
pub fn rowRect(area: Rect, row: usize) Rect {
    return .{ .x = area.x, .y = area.y + pad + @as(i32, @intCast(row)) * row_h, .w = area.w, .h = row_h };
}

/// The breakpoint square in row `row`'s gutter.
pub fn markRect(area: Rect, row: usize) Rect {
    const band = rowRect(area, row);
    return .{ .x = area.x + pad + 2, .y = band.y + 3, .w = font.glyph_w, .h = row_h - 6 };
}

pub fn draw(list: *draw_list.DrawList, area: Rect, snapshot: *const Snapshot, marks: *const Marks) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    var message: [path_cap + 32]u8 = undefined;
    switch (snapshot.state) {
        .no_line => return drawText(list, area, 0, text_at, try std.fmt.bufPrint(&message, "No line information for 0x{X:0>8}", .{snapshot.pc}), muted),
        .no_file => return drawText(list, area, 0, text_at, try std.fmt.bufPrint(&message, "{s}: No such file", .{snapshot.path()}), muted),
        .shown => {},
    }
    for (0..@min(rows(area), snapshot.count)) |row| {
        const line = &snapshot.rows[row];
        const current = line.number == snapshot.current;
        if (current) try list.fill(rowRect(area, row), current_band);
        if (marks.find(snapshot.path(), line.number) != null) try list.fill(markRect(area, row), break_mark);
        if (current) try drawText(list, area, row, 1, ">", current_ink);
        var number: [number_len]u8 = undefined;
        try drawText(list, area, row, number_at, try std.fmt.bufPrint(&number, "{d: >5}", .{line.number}), if (current) current_ink else muted);
        try drawText(list, area, row, text_at, line.text(), ink);
    }
}

fn drawText(list: *draw_list.DrawList, area: Rect, row: usize, at: usize, text: []const u8, color: Color) !void {
    const x = area.x + pad + 2 + column(at);
    const room: u32 = @intCast(@max(area.x + area.w - pad - x, 0));
    try font.draw(list, x, rowRect(area, row).y + 2, font.fit(text, room), color);
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}
