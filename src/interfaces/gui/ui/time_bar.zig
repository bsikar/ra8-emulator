//! The time bar (RA8EMU-807): run, pause and step buttons, the speed field
//! and the clock readout as one row of draw-list commands, plus the hit test
//! that maps a click to a control. It paints plain values; the status, the
//! speed field and the readout models fill them in gui/time.bar_capture.zig,
//! which also turns a click into a run, step or pause (RA8EMU-1086). The shell
//! (RA8EMU-201) places the bar; this file only lays it out, paints it and
//! answers clicks.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;
const speed_field = @import("../speed_field.zig");
const time_bar_paint = @import("time_bar_paint.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
pub const gap: i32 = 4;
/// A control is a glyph with three pixels of air above and below.
pub const control_h: i32 = font.glyph_h + 6;
/// The controls, a pixel of border on top, and air around them.
pub const height: i32 = control_h + 7;
/// Room for a full elapsed segment before the optional speed field.
pub const clock_min: i32 = 13 * font.cell_w + 2 * pad;
/// The longest speed text the field shows; gui/time.bar_capture.zig pins it
/// to the speed field's own limit.
pub const field_chars: usize = 12;
/// The longest seek target the seek field shows; gui/time.bar_capture.zig
/// pins it to the seek field's own limit.
pub const seek_chars: usize = 20;
pub const drop_w: i32 = 14;
pub const drop_row_h: i32 = font.glyph_h + 4;
pub const drop_popover_h: i32 = 1 + @as(i32, @intCast(speed_field.presets.len)) * drop_row_h;

pub const Control = enum {
    run,
    pause,
    step,
    over,
    out,
    field,
    drop,
    seek,

    pub fn label(self: Control) []const u8 {
        return switch (self) {
            .run => "Run",
            .pause => "Pause",
            .step => "Step",
            .over => "Over",
            .out => "Out",
            .field, .drop, .seek => "",
        };
    }
};

/// Where each control sits in a bar, left to right, each cut to the bar; the
/// clock takes what is left. A control that does not fit comes out empty.
pub const Layout = struct {
    run: Rect,
    pause: Rect,
    step: Rect,
    over: Rect,
    out: Rect,
    field: Rect,
    seek: Rect,
    clock: Rect,

    pub fn of(bar: Rect) Layout {
        const top = bar.y + 1 + draw_list.centre(bar.h - 1, control_h);
        var x = bar.x + pad;
        const run = place(bar, &x, top, .run);
        const pause_at = if (run.empty()) run else place(bar, &x, top, .pause);
        const step = if (pause_at.empty()) pause_at else place(bar, &x, top, .step);
        const over = if (step.empty()) step else place(bar, &x, top, .over);
        const out = if (over.empty()) over else place(bar, &x, top, .out);
        const field = if (out.empty() or bar.x + bar.w - pad - x < width(.field) + gap + clock_min)
            Rect{ .x = x, .y = top, .w = 0, .h = 0 }
        else
            place(bar, &x, top, .field);
        const seek = if (field.empty() or bar.x + bar.w - pad - x < width(.seek) + gap + clock_min)
            Rect{ .x = x, .y = top, .w = 0, .h = 0 }
        else
            place(bar, &x, top, .seek);
        const clock_rect = bar.intersect(.{ .x = x, .y = top, .w = bar.x + bar.w - pad - x, .h = control_h });
        return .{ .run = run, .pause = pause_at, .step = step, .over = over, .out = out, .field = field, .seek = seek, .clock = clock_rect };
    }

    /// Only whole controls have paint and hit targets. Leave room for the clock.
    fn place(bar: Rect, x: *i32, top: i32, control: Control) Rect {
        const w = width(control);
        const wanted: Rect = .{ .x = x.*, .y = top, .w = w, .h = control_h };
        const at = bar.intersect(wanted);
        if (at.w != w or at.h != control_h or x.* + w > bar.x + bar.w - pad)
            return .{ .x = x.*, .y = top, .w = 0, .h = 0 };
        x.* += w + gap;
        return at;
    }

    pub fn rect(self: Layout, control: Control) Rect {
        return switch (control) {
            .run => self.run,
            .pause => self.pause,
            .step => self.step,
            .over => self.over,
            .out => self.out,
            .field => self.field,
            .seek => self.seek,
            .drop => dropBox(self.field),
        };
    }
};

/// A button fits its label with a pad each side; the field fits its longest text and the arrow.
pub fn width(control: Control) i32 {
    const chars = switch (control) {
        .field => field_chars,
        .seek => seek_chars,
        .drop => 0,
        else => control.label().len,
    };
    const text: i32 = @as(i32, @intCast(font.textWidth(chars))) + 2 * pad;
    return switch (control) {
        .drop => drop_w,
        .field => text + drop_w,
        else => text,
    };
}

pub fn dropBox(field: Rect) Rect {
    if (field.empty() or field.w < drop_w) return .{ .x = field.x, .y = field.y, .w = 0, .h = 0 };
    return .{ .x = field.x + field.w - drop_w, .y = field.y, .w = drop_w, .h = field.h };
}

pub fn popover(field: Rect) Rect {
    return .{ .x = field.x, .y = field.y - drop_popover_h, .w = field.w, .h = drop_popover_h };
}

pub fn popoverRow(field: Rect, index: usize) Rect {
    const box = popover(field);
    return .{ .x = box.x + 1, .y = box.y + 1 + @as(i32, @intCast(index)) * drop_row_h, .w = box.w - 2, .h = drop_row_h };
}

pub fn hitDropdown(field: Rect, open: bool, x: i32, y: i32) ?usize {
    if (!open or field.empty()) return null;
    const box = popover(field);
    if (!box.contains(x, y)) return null;
    for (0..speed_field.presets.len) |index| {
        if (popoverRow(field, index).contains(x, y)) return index;
    }
    return null;
}

/// What the bar paints, as plain values filled from the models that own them.
pub const View = struct {
    run_lit: bool = false,
    pause_lit: bool = false,
    run_enabled: bool = false,
    pause_enabled: bool = false,
    step_enabled: bool = false,
    over_enabled: bool = false,
    out_enabled: bool = false,
    note: ?[]const u8 = null,
    command_refused: bool = false,
    field: []const u8 = "",
    field_refused: bool = false,
    seek: []const u8 = "",
    seek_editing: bool = false,
    editing: bool = false,
    open: bool = false,
    applied: ?u64 = null,
    clock: []const u8 = "",
    clock_date: ?[]const u8 = null,
    clock_speed: ?[]const u8 = null,
};

pub const draw = time_bar_paint.draw;

pub fn hit(bar: Rect, x: i32, y: i32) ?Control {
    const layout = Layout.of(bar);
    for ([_]Control{ .run, .pause, .step, .over, .out }) |control| {
        if (layout.rect(control).contains(x, y)) return control;
    }
    if (layout.field.contains(x, y)) {
        if (dropBox(layout.field).contains(x, y)) return .drop;
        return .field;
    }
    if (layout.seek.contains(x, y)) return .seek;
    return null;
}
