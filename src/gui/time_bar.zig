//! The time bar (RA8EMU-807): run, pause and step buttons, the speed field
//! and the clock readout as one row of draw-list commands, plus the hit test
//! that maps a click to a control. Run, pause and step go through the status
//! bar's go and pause (RA8EMU-752); the field and the readout are their own
//! models (RA8EMU-808, RA8EMU-806). The shell (RA8EMU-201) places the bar;
//! this file only lays it out, paints it and answers clicks.
const std = @import("std");
const proto = @import("../interfaces/rpc/session_rpc.zig");
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const status_bar = @import("status_bar.zig");
const speed_field = @import("speed_field.zig");
const time_readout = @import("time_readout.zig");
const session_link = @import("session_link.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Status = status_bar.Status;
const Link = session_link.Link;

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const border = Color.rgb(0x4A, 0x51, 0x5C);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const muted = Color.rgb(0x9A, 0xA5, 0xB4);
pub const face = Color.rgb(0x2C, 0x31, 0x3A);
pub const lit = Color.rgb(0x61, 0xAF, 0xEF);
pub const well = Color.rgb(0x1B, 0x1F, 0x24);
pub const refused = Color.rgb(0xE0, 0x6C, 0x75);
pub const pad: i32 = 4;
pub const gap: i32 = 4;
/// A control is a glyph with three pixels of air above and below.
pub const control_h: i32 = font.glyph_h + 6;
/// The controls, a pixel of border on top, and air around them.
pub const height: i32 = control_h + 7;
/// A step is one instruction; the session takes no budget for it.
pub const step_budget: u64 = 0;

pub const Control = enum {
    run,
    pause,
    step,
    field,

    pub fn label(self: Control) []const u8 {
        return switch (self) {
            .run => "Run",
            .pause => "Pause",
            .step => "Step",
            .field => "",
        };
    }
};

/// Where each control sits in a bar, left to right, each cut to the bar; the
/// clock takes what is left. A control that does not fit comes out empty.
pub const Layout = struct {
    run: Rect,
    pause: Rect,
    step: Rect,
    field: Rect,
    clock: Rect,

    pub fn of(bar: Rect) Layout {
        const top = bar.y + 1 + @divTrunc(bar.h - 1 - control_h, 2);
        var x = bar.x + pad;
        const run = place(bar, &x, top, .run);
        const pause_at = place(bar, &x, top, .pause);
        const step = place(bar, &x, top, .step);
        const field = place(bar, &x, top, .field);
        const clock = bar.intersect(.{ .x = x, .y = top, .w = bar.x + bar.w - pad - x, .h = control_h });
        return .{ .run = run, .pause = pause_at, .step = step, .field = field, .clock = clock };
    }

    /// The next control at `x.*`, cut to the bar; moves `x` past it and the gap.
    fn place(bar: Rect, x: *i32, top: i32, control: Control) Rect {
        const w = width(control);
        const at = bar.intersect(.{ .x = x.*, .y = top, .w = w, .h = control_h });
        x.* += w + gap;
        return at;
    }

    pub fn rect(self: Layout, control: Control) Rect {
        return switch (control) {
            .run => self.run,
            .pause => self.pause,
            .step => self.step,
            .field => self.field,
        };
    }
};

/// A button fits its label with a pad each side; the field fits its longest text.
pub fn width(control: Control) i32 {
    const chars = if (control == .field) speed_field.max_chars else control.label().len;
    return @as(i32, @intCast(font.textWidth(chars))) + 2 * pad;
}

/// What the bar paints, borrowed from the models that own it.
pub const View = struct {
    status: *const Status,
    field: *const speed_field.Field,
    readout: *const time_readout.Readout,
    /// The field has the keyboard: it reads what is typed and shows a caret.
    editing: bool = false,
};

pub fn draw(list: *draw_list.DrawList, bar: Rect, view: View) !void {
    if (bar.empty()) return;
    try list.pushClip(bar);
    defer list.popClip();
    try list.fill(bar, background);
    try list.fill(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, border);
    const layout = Layout.of(bar);
    for ([_]Control{ .run, .pause, .step }) |control| {
        try button(list, layout.rect(control), control.label(), lights(control, view.status));
    }
    try fieldBox(list, layout.field, view);
    var buf: [96]u8 = undefined;
    const clock = view.readout.text(view.field.applied, &buf) catch buf[0..0];
    try text(list, layout.clock, clock, muted);
}

/// Run lights while the core runs; Pause lights while it is halted.
fn lights(control: Control, status: *const Status) bool {
    return switch (control) {
        .run => status.run == .running,
        .pause => status.run == .halted,
        .step, .field => false,
    };
}

fn button(list: *draw_list.DrawList, area: Rect, label: []const u8, on: bool) !void {
    if (area.empty()) return;
    try list.fill(area, if (on) lit else face);
    try font.centred(list, area, label, if (on) background else ink);
}

fn fieldBox(list: *draw_list.DrawList, area: Rect, view: View) !void {
    if (area.empty()) return;
    try list.fill(area, well);
    try outline(list, area, if (view.field.refused != null) refused else if (view.editing) lit else border);
    var buf: [speed_field.max_chars + 4]u8 = undefined;
    const shown = view.field.shown(&buf) catch buf[0..0];
    try text(list, area, shown, ink);
    if (!view.editing) return;
    const caret_x = area.x + pad + @as(i32, @intCast(font.textWidth(shown.len)));
    try list.fill(.{ .x = caret_x, .y = area.y + 2, .w = 1, .h = area.h - 4 }, ink);
}

fn outline(list: *draw_list.DrawList, area: Rect, color: Color) !void {
    try list.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, color);
    try list.fill(.{ .x = area.x, .y = area.y + area.h - 1, .w = area.w, .h = 1 }, color);
    try list.fill(.{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, color);
    try list.fill(.{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h }, color);
}

/// `line` from a pad in, centred down `area`, cut to whole cells inside it.
fn text(list: *draw_list.DrawList, area: Rect, line: []const u8, color: Color) !void {
    const room = area.w - 2 * pad;
    if (room <= 0) return;
    const shown = font.fit(line, @intCast(room));
    const top = area.y + @divTrunc(area.h - @as(i32, font.glyph_h), 2);
    try font.draw(list, area.x + pad, top, shown, color);
}

/// The control under (`x`, `y`) in `bar`, or null for the gaps and the clock.
pub fn hit(bar: Rect, x: i32, y: i32) ?Control {
    const layout = Layout.of(bar);
    for ([_]Control{ .run, .pause, .step, .field }) |control| {
        if (layout.rect(control).contains(x, y)) return control;
    }
    return null;
}

/// A click on `control`. Run continues from wherever the core stopped (the
/// session refuses a fresh run once started) for `run_budget` instructions;
/// Step runs one; Pause asks the session to stop. The field takes the
/// keyboard in the shell, so a click on it sends nothing.
pub fn press(control: Control, status: *Status, link: *Link, run_budget: u64) !void {
    switch (control) {
        .run => try status.go(link, proto.RunMode.cont, run_budget),
        .step => try status.go(link, proto.RunMode.step, step_budget),
        .pause => try status.pause(link),
        .field => {},
    }
}
