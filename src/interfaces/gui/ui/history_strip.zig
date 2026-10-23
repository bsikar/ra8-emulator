//! The history strip: the machine-history track the time bar sits on. The
//! recorded part fills one band, the unrun tail hatches, checkpoint marks
//! tick the recorded part and the cursor shows where the run stands. It
//! paints plain draw-list commands and maps a click's x to a fraction the
//! bar_capture turns into a seek; the track model and its span live in
//! gui/history_track.zig. The shell places it; this file only lays out,
//! paints and answers clicks.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;
const history_track = @import("../history_track.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// The strip's height, one border pixel of air above and below the track.
pub const height: i32 = 16;
/// Air between the strip's edges and the track.
pub const pad: i32 = 4;
/// The unrun tail hatches: two columns of ink every four pixels.
pub const hatch_step: i32 = 4;
pub const hatch_w: i32 = 2;

/// What the strip paints: the track model plus the checkpoints to tick.
pub const View = struct {
    track: history_track.Track = .{},
    marks: []const history_track.Mark = &.{},
};

/// The track's area inside the strip: one pixel of border above and below,
/// `pad` of air left and right.
pub fn body(strip: Rect) Rect {
    return .{
        .x = strip.x + pad,
        .y = strip.y + 1,
        .w = @max(0, strip.w - 2 * pad),
        .h = @max(0, strip.h - 2),
    };
}

/// A fraction of the span (0 to 1) as an x inside the strip's body,
/// clamped to its ends.
pub fn fractionToX(fraction: f64, strip: Rect) i32 {
    const b = body(strip);
    const clamped = @max(0.0, @min(1.0, fraction));
    return b.x + @as(i32, @intFromFloat(@round(clamped * @as(f64, @floatFromInt(b.w)))));
}

/// An x inside the strip as a fraction of the span, or null outside the
/// body; the ends answer exactly 0 and 1.
pub fn xToFraction(strip: Rect, x: i32) ?f64 {
    const b = body(strip);
    if (b.w <= 0) return null;
    if (x < b.x or x > b.x + b.w) return null;
    return @as(f64, @floatFromInt(x - b.x)) / @as(f64, @floatFromInt(b.w));
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, strip: Rect, view: View) void {
    if (strip.empty()) return;
    table.push_clip.?(table.user, strip.x, strip.y, strip.w, strip.h);
    fill(table, strip, theme.well);
    const b = body(strip);
    const total = view.track.total();
    if (total > 0 and b.w > 0) {
        const end = view.track.end_ns.?;
        const recorded_x = fractionToX(@as(f64, @floatFromInt(end)) / @as(f64, @floatFromInt(total)), strip);
        fill(table, .{ .x = b.x, .y = b.y, .w = recorded_x - b.x, .h = b.h }, theme.band);
        var x: i32 = recorded_x;
        while (x + hatch_w <= b.x + b.w) : (x += hatch_step) {
            fill(table, .{ .x = x, .y = b.y, .w = hatch_w, .h = b.h }, theme.muted);
        }
        for (view.marks) |mark| {
            const mx = fractionToX(@as(f64, @floatFromInt(mark.ns)) / @as(f64, @floatFromInt(total)), strip);
            fill(table, .{ .x = mx, .y = b.y, .w = 1, .h = b.h }, theme.accent);
        }
        if (view.track.cursorFraction()) |fraction| {
            fill(table, .{ .x = fractionToX(fraction, strip), .y = strip.y, .w = 1, .h = strip.h }, theme.pc_cyan);
        }
    }
    table.pop_clip.?(table.user);
}

fn fill(table: *const widget.types.Paint, r: Rect, color: Color) void {
    if (r.empty()) return;
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
