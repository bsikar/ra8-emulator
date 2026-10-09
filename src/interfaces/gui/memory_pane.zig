//! The memory pane (RA8EMU-746): a hex dump of one core's memory, Ozone
//! style. Each row is an eight-digit address, sixteen bytes in hex with a
//! gap after the eighth, then the same bytes as ASCII. A byte the session
//! cannot read draws as "??" in the hex and '?' in the ASCII, both muted.
//!
//! `capture` reads the session from a base address; `draw` reads only the
//! snapshot, so the shell scrolls by capturing again at a new base.
const std = @import("std");
const draw_list = @import("../../render/draw_list.zig");
const font = @import("../../render/font.zig");
const session_api = @import("../../session/session_api.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const muted = Color.rgb(0x9A, 0xA5, 0xB4);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const per_row: usize = 16;
/// The most rows one snapshot holds: more than any pane shows at once.
pub const max_rows: usize = 64;
/// Characters before the hex: eight address digits and a gap.
pub const hex_at: usize = 10;
/// Characters before the ASCII: the hex bytes, the gap after the eighth
/// byte, and two more.
pub const ascii_at: usize = hex_at + per_row * 3 + 2;
pub const row_len: usize = ascii_at + per_row;
/// The narrowest pane that holds a whole row.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(row_len)));

const cells = max_rows * per_row;

pub const Snapshot = struct {
    base: u32 = 0,
    /// Rows captured, from `base` up.
    count: usize = 0,
    bytes: [cells]u8 = @splat(0),
    readable: [cells]bool = @splat(false),

    pub fn rowAddress(self: *const Snapshot, row: usize) u32 {
        return self.base +% @as(u32, @intCast(row * per_row));
    }
};

/// Reads `row_count` rows (at most `max_rows`) of `core`'s memory from
/// `base` through the session. A row the bus refuses is read again a byte
/// at a time, so a row straddling the end of a region keeps its readable
/// part. Errors that are not about one address, like a core that is not
/// attached, are returned.
pub fn capture(session: *session_api.Session, core: session_api.Core, base: u32, row_count: usize) anyerror!Snapshot {
    var snapshot: Snapshot = .{ .base = base, .count = @min(row_count, max_rows) };
    for (0..snapshot.count) |row| try captureRow(session, core, &snapshot, row);
    return snapshot;
}

fn captureRow(session: *session_api.Session, core: session_api.Core, snapshot: *Snapshot, row: usize) anyerror!void {
    const start = row * per_row;
    session.read(core, snapshot.rowAddress(row), snapshot.bytes[start..][0..per_row]) catch |err| {
        if (!unreadable(err)) return err;
        return captureBytes(session, core, snapshot, row);
    };
    @memset(snapshot.readable[start..][0..per_row], true);
}

fn captureBytes(session: *session_api.Session, core: session_api.Core, snapshot: *Snapshot, row: usize) anyerror!void {
    const start = row * per_row;
    for (0..per_row) |index| {
        const address = snapshot.rowAddress(row) +% @as(u32, @intCast(index));
        session.read(core, address, snapshot.bytes[start + index ..][0..1]) catch |err| {
            if (unreadable(err)) continue;
            return err;
        };
        snapshot.readable[start + index] = true;
    }
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

/// The character column byte `index` of a row starts at.
pub fn hexColumn(index: usize) usize {
    return hex_at + index * 3 + @intFromBool(index >= per_row / 2);
}

/// Where row `row`'s text starts.
pub fn rowOrigin(area: Rect, row: usize) struct { x: i32, y: i32 } {
    return .{ .x = area.x + pad + 2, .y = area.y + pad + 2 + @as(i32, @intCast(row)) * row_h };
}

pub fn draw(list: *draw_list.DrawList, area: Rect, snapshot: *const Snapshot) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    for (0..@min(rows(area), snapshot.count)) |row| try drawRow(list, area, snapshot, row);
}

fn drawRow(list: *draw_list.DrawList, area: Rect, snapshot: *const Snapshot, row: usize) !void {
    const at = rowOrigin(area, row);
    var buffer: [8]u8 = undefined;
    try font.draw(list, at.x, at.y, try std.fmt.bufPrint(&buffer, "{X:0>8}", .{snapshot.rowAddress(row)}), muted);
    for (0..per_row) |index| {
        const cell = row * per_row + index;
        try drawByte(list, at.x, at.y, index, snapshot.bytes[cell], snapshot.readable[cell]);
    }
}

fn drawByte(list: *draw_list.DrawList, x: i32, y: i32, index: usize, byte: u8, readable: bool) !void {
    const hex_x = x + column(hexColumn(index));
    const ascii_x = x + column(ascii_at + index);
    if (!readable) {
        try font.draw(list, hex_x, y, "??", muted);
        return font.draw(list, ascii_x, y, "?", muted);
    }
    var buffer: [2]u8 = undefined;
    try font.draw(list, hex_x, y, try std.fmt.bufPrint(&buffer, "{X:0>2}", .{byte}), ink);
    const printable = byte >= 0x21 and byte < 0x7F;
    const shown = [1]u8{if (printable) byte else '.'};
    try font.draw(list, ascii_x, y, &shown, if (printable) ink else muted);
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}
