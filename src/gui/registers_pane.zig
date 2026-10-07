//! The registers pane (RA8EMU-741): one core's registers, RAD Debugger
//! style, a name column and an eight-digit hex value, run down a column and
//! then across as many columns as the area holds. A value that differs from
//! the snapshot taken before the last run or step draws in `changed`, so a
//! step shows what it touched.
//!
//! `capture` reads the session for CPU0 or CPU1; `draw` reads only the
//! snapshot, so the shell redraws without touching a core.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const session_api = @import("../debug/session_api.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Register = session_api.Register;

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const muted = Color.rgb(0x9A, 0xA5, 0xB4);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const changed = Color.rgb(0xE5, 0xC0, 0x7B);
pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
/// Characters a name takes: "faultmask" plus a gap.
pub const name_len: usize = 10;
/// Characters one column takes: the name, eight hex digits and a gap.
pub const column_len: usize = name_len + 8 + 2;

/// The order the pane shows: the general registers, the three that say
/// where execution is, status, both stack pointers, the masks, CONTROL and
/// FPSCR.
pub const shown = [_]Register{
    .r0,   .r1,  .r2,  .r3,      .r4,      .r5,        .r6,      .r7,
    .r8,   .r9,  .r10, .r11,     .r12,     .sp,        .lr,      .pc,
    .xpsr, .msp, .psp, .primask, .basepri, .faultmask, .control, .fpscr,
};

pub const Snapshot = struct {
    values: [shown.len]u32 = @splat(0),

    /// Did register `index` change since `before`? Nothing has changed
    /// when there is no earlier snapshot.
    pub fn changedAt(self: Snapshot, before: ?Snapshot, index: usize) bool {
        const old = before orelse return false;
        return old.values[index] != self.values[index];
    }
};

/// Reads every shown register of `core` through the session.
pub fn capture(session: *session_api.Session, core: session_api.Core) anyerror!Snapshot {
    var snapshot: Snapshot = .{};
    for (shown, 0..) |which, index| snapshot.values[index] = try session.register(core, which);
    return snapshot;
}

/// How many cells fit down one column of `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// How many columns fit across `area`.
pub fn columns(area: Rect) usize {
    const inner = area.w - 2 * pad;
    const width: i32 = @intCast(font.textWidth(column_len));
    if (inner < width) return 0;
    return @intCast(@divTrunc(inner, width));
}

/// Register `index`'s cell, or null when it does not fit.
pub fn cellRect(area: Rect, index: usize) ?Rect {
    const down = rows(area);
    if (down == 0) return null;
    const column = index / down;
    if (column >= columns(area)) return null;
    const width: i32 = @intCast(font.textWidth(column_len));
    return .{
        .x = area.x + pad + @as(i32, @intCast(column)) * width,
        .y = area.y + pad + @as(i32, @intCast(index % down)) * row_h,
        .w = width,
        .h = row_h,
    };
}

/// Where register `index`'s value text starts inside its cell.
pub fn valueOrigin(cell: Rect) struct { x: i32, y: i32 } {
    return .{ .x = cell.x + 2 + @as(i32, @intCast(font.textWidth(name_len))), .y = cell.y + 2 };
}

pub fn draw(list: *draw_list.DrawList, area: Rect, now: Snapshot, before: ?Snapshot) !void {
    if (cellRect(area, 0) == null) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    for (shown, 0..) |which, index| {
        const cell = cellRect(area, index) orelse break;
        try drawCell(list, cell, which, now.values[index], now.changedAt(before, index));
    }
}

fn drawCell(list: *draw_list.DrawList, cell: Rect, which: Register, value: u32, moved: bool) !void {
    try font.draw(list, cell.x + 2, cell.y + 2, @tagName(which), muted);
    var buffer: [8]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{X:0>8}", .{value});
    const at = valueOrigin(cell);
    try font.draw(list, at.x, at.y, text, if (moved) changed else ink);
}
