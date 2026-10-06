//! The disassembly pane (RA8EMU-743): instructions decoded forward from a
//! start address, RAD Debugger style. Each row is a gutter (a red square on
//! a breakpoint, an amber '>' at pc), the address, the instruction's
//! halfwords and its text. The pc row sits on a full-width band.
//!
//! Thumb cannot be decoded backwards reliably, so `capture` starts where the
//! caller says: pc to follow execution, or the shell's scroll anchor. `draw`
//! reads only the snapshot and the breakpoint addresses it is handed.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const disasm = @import("../debug/disasm.zig");
const session_api = @import("../debug/session_api.zig");
const session_view = @import("../debug/session_view.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const muted = Color.rgb(0x9A, 0xA5, 0xB4);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const pc_band = Color.rgb(0x2F, 0x3B, 0x4C);
pub const pc_ink = Color.rgb(0xE5, 0xC0, 0x7B);
pub const break_mark = Color.rgb(0xE0, 0x6C, 0x75);
pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const max_rows: usize = 64;
/// Characters of instruction text a line keeps.
pub const text_cap: usize = 48;
/// Character columns: the gutter, the address, the halfwords, the text.
pub const address_at: usize = 2;
pub const bytes_at: usize = address_at + 8 + 2;
pub const text_at: usize = bytes_at + 9 + 2;
/// The narrowest pane: the columns before the text and room for 16 more.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(text_at + 16)));

pub const Line = struct {
    address: u32 = 0,
    /// 2 or 4 bytes; 0 when the instruction could not be read.
    size: u8 = 0,
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    decoded: bool = false,
    text_buf: [text_cap]u8 = undefined,
    text_len: usize = 0,

    pub fn text(self: *const Line) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn setText(self: *Line, from: []const u8) void {
        self.text_len = @min(from.len, text_cap);
        @memcpy(self.text_buf[0..self.text_len], from[0..self.text_len]);
    }
};

pub const Snapshot = struct {
    pc: u32 = 0,
    count: usize = 0,
    lines: [max_rows]Line = [_]Line{.{}} ** max_rows,
};

/// Decodes `row_count` instructions (at most `max_rows`) of `core` forward
/// from `start`, and reads its pc. An instruction that cannot be read takes
/// two bytes and the next one starts after it. Errors that are not about
/// one address, like a core that is not attached, are returned.
pub fn capture(session: *session_api.Session, core: session_api.Core, start: u32, row_count: usize) anyerror!Snapshot {
    var snapshot: Snapshot = .{ .pc = try session.register(core, .pc), .count = @min(row_count, max_rows) };
    var at = start;
    for (snapshot.lines[0..snapshot.count]) |*line| {
        line.* = try decode(session, core, at);
        at +%= if (line.size == 0) session_view.encoding.narrow else line.size;
    }
    return snapshot;
}

fn decode(session: *session_api.Session, core: session_api.Core, address: u32) anyerror!Line {
    var line: Line = .{ .address = address };
    session.read(core, address, line.bytes[0..2]) catch |err| {
        if (unreadable(err)) return line;
        return err;
    };
    const first = std.mem.readInt(u16, line.bytes[0..2], .little);
    const wide = first >= session_view.encoding.wide_first;
    if (wide) session.read(core, address +% 2, line.bytes[2..4]) catch |err| {
        if (unreadable(err)) return line;
        return err;
    };
    line.size = if (wide) 4 else 2;
    const decoded = disasm.one(address, line.bytes[0..line.size]) catch return line;
    line.setText(decoded.slice());
    line.decoded = true;
    return line;
}

/// The bus errors that mean this address cannot be read.
fn unreadable(err: anyerror) bool {
    return err == error.Unmapped or err == error.SecurityViolation;
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

pub fn draw(list: *draw_list.DrawList, area: Rect, snapshot: *const Snapshot, breaks: []const u32) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    for (0..@min(rows(area), snapshot.count)) |row| {
        const line = &snapshot.lines[row];
        const at_pc = line.address == snapshot.pc;
        if (at_pc) try list.fill(rowRect(area, row), pc_band);
        if (std.mem.indexOfScalar(u32, breaks, line.address) != null) try list.fill(markRect(area, row), break_mark);
        try drawLine(list, area, row, line, at_pc);
    }
}

fn drawLine(list: *draw_list.DrawList, area: Rect, row: usize, line: *const Line, at_pc: bool) !void {
    const x = area.x + pad + 2;
    const y = rowRect(area, row).y + 2;
    if (at_pc) try font.draw(list, x + column(1), y, ">", pc_ink);
    var address: [8]u8 = undefined;
    try font.draw(list, x + column(address_at), y, try std.fmt.bufPrint(&address, "{X:0>8}", .{line.address}), if (at_pc) pc_ink else muted);
    var halves: [9]u8 = undefined;
    try font.draw(list, x + column(bytes_at), y, try halfwords(&halves, line), muted);
    const shown = if (line.decoded) line.text() else if (line.size == 0) "<unreadable>" else "<undecoded>";
    const text_x = x + column(text_at);
    const room: u32 = @intCast(@max(area.x + area.w - pad - text_x, 0));
    try font.draw(list, text_x, y, font.fit(shown, room), if (line.decoded) ink else muted);
}

fn halfwords(buffer: *[9]u8, line: *const Line) ![]const u8 {
    const first = std.mem.readInt(u16, line.bytes[0..2], .little);
    const second = std.mem.readInt(u16, line.bytes[2..4], .little);
    return switch (line.size) {
        2 => std.fmt.bufPrint(buffer, "{x:0>4}", .{first}),
        4 => std.fmt.bufPrint(buffer, "{x:0>4} {x:0>4}", .{ first, second }),
        else => "????",
    };
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}
