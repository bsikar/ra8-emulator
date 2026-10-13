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

pub const Control = enum {
    run,
    pause,
    step,
    over,
    out,
    field,

    pub fn label(self: Control) []const u8 {
        return switch (self) {
            .run => "Run",
            .pause => "Pause",
            .step => "Step",
            .over => "Over",
            .out => "Out",
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
    over: Rect,
    out: Rect,
    field: Rect,
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
        const clock_rect = bar.intersect(.{ .x = x, .y = top, .w = bar.x + bar.w - pad - x, .h = control_h });
        return .{ .run = run, .pause = pause_at, .step = step, .over = over, .out = out, .field = field, .clock = clock_rect };
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
        };
    }
};

/// A button fits its label with a pad each side; the field fits its longest text.
pub fn width(control: Control) i32 {
    const chars = if (control == .field) field_chars else control.label().len;
    return @as(i32, @intCast(font.textWidth(chars))) + 2 * pad;
}

/// What the bar paints, as plain values filled from the models that own them.
pub const View = struct {
    /// Run lights while the core runs; Pause lights while it is halted.
    run_lit: bool = false,
    pause_lit: bool = false,
    run_enabled: bool = false,
    pause_enabled: bool = false,
    step_enabled: bool = false,
    over_enabled: bool = false,
    out_enabled: bool = false,
    /// Concise command refusal or unavailable reason, after elapsed time.
    note: ?[]const u8 = null,
    command_refused: bool = false,
    /// What the speed field shows.
    field: []const u8 = "",
    /// The session refused the last speed sent.
    field_refused: bool = false,
    /// The field has the keyboard: it reads what is typed and shows a caret.
    editing: bool = false,
    /// The clock readout's elapsed segment, "T+h:mm:ss.mmm" (RA8EMU-941).
    clock: []const u8 = "",
    /// The readout's date and speed segments; the bar drops whole ones that
    /// do not fit, the speed first, then the date.
    clock_date: ?[]const u8 = null,
    clock_speed: ?[]const u8 = null,
};

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, bar: Rect, view: View) void {
    if (bar.empty()) return;
    table.push_clip.?(table.user, bar.x, bar.y, bar.w, bar.h);
    defer table.pop_clip.?(table.user);
    fillArea(table, bar, theme.ribbon_bg);
    fillArea(table, .{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, theme.border);
    const layout = Layout.of(bar);
    for ([_]Control{ .run, .pause, .step, .over, .out }) |control| {
        button(table, theme, layout.rect(control), control, view);
    }
    fieldBox(table, theme, layout.field, view);
    clock(table, theme, layout.clock, view);
}

fn fillArea(table: *const widget.types.Paint, r: Rect, color: Color) void {
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

/// `text` drawn at (x, y) through the shared Paint table; `bg` is the fill
/// already under the text's cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: Color, bg: Color) void {
    var buffer: [256]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = word(fg),
        .bg = word(bg),
        .pad = 0,
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{
        .x = x,
        .y = y,
        .w = @intCast(font.textWidth(text.len)),
        .h = @intCast(font.cell_h),
    };
    w.vt.?.render.?(&w);
}

fn lights(control: Control, view: View) bool {
    return switch (control) {
        .run => view.run_lit,
        .pause => view.pause_lit,
        .step, .over, .out, .field => false,
    };
}

/// The control as the firmware's push-button widget (RA8EMU-1158): the
/// widget owns the face, border and label look; the theme only fills the
/// descriptor, with the lit look on `face_pressed`.
fn button(paint: *const widget.types.Paint, theme: *const Theme, area: Rect, control: Control, view: View) void {
    if (area.empty()) return;
    const enabled = switch (control) {
        .run => view.run_enabled,
        .pause => view.pause_enabled,
        .step => view.step_enabled,
        .over => view.over_enabled,
        .out => view.out_enabled,
        .field => true,
    };
    const on = lights(control, view) and (enabled or control == .run);
    var descriptor = widget.button.Button{
        .paint = paint,
        .text = switch (control) {
            .run => "Run",
            .pause => "Pause",
            .step => "Step",
            .over => "Over",
            .out => "Out",
            .field => "",
        },
        .on_press = null,
        .fg = word(if (on) theme.background else if (!enabled) theme.muted else theme.ink),
        .face = word(theme.face),
        .face_pressed = word(switch (control) {
            .run => theme.runLit(),
            .pause => theme.pauseLit(),
            .step, .over, .out => theme.step_active,
            .field => theme.accent,
        }),
        .border = word(if (on) switch (control) {
            .run => theme.good,
            .pause => theme.highlight,
            .step, .over, .out => theme.step_active,
            .field => theme.accent,
        } else theme.control_border),
        .presses = 0,
        .pad = 3,
        .border_w = 1,
        .alignment = .center,
        .pressed = on,
        .reserved = 0,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.button.ra8_widget_button_init(&w, &descriptor);
    w.rect = .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h };
    w.vt.?.render.?(&w);
}

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

/// The clock readout as the firmware's label widget, one line on the bar's
/// own background. A left-aligned label sets its text one pad in from its
/// corner, so the label is given the centring offset as its pad and starts
/// far enough right to keep the text a `pad` in: the readout then stands
/// on the same row as the button labels and the speed field (RA8EMU-1168).
/// The line is whole segments that fit (RA8EMU-941), so the bar's clip only
/// ever keeps paint inside the bar.
fn clock(paint: *const widget.types.Paint, theme: *const Theme, area: Rect, view: View) void {
    const room = area.w - 2 * pad;
    if (area.empty() or room <= 0) return;
    var line: [160]u8 = undefined;
    const shown = fitClock(view, room, &line);
    var buf: [160]u8 = undefined;
    const n = @min(shown.len, buf.len - 1);
    @memcpy(buf[0..n], shown[0..n]);
    buf[n] = 0;
    const down = draw_list.centre(area.h, font.glyph_h);
    var descriptor = widget.label.Label{
        .paint = paint,
        .text = buf[0..n :0].ptr,
        .fg = word(if (view.command_refused) theme.bad else theme.muted),
        .bg = word(theme.ribbon_bg),
        .pad = @intCast(down),
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{ .x = area.x + pad - down, .y = area.y, .w = area.w - (pad - down), .h = area.h };
    w.vt.?.render.?(&w);
}

/// The richest line of whole segments that fits `room` pixels (RA8EMU-941):
/// the achieved speed and then the date are dropped whole before any part
/// of the elapsed segment is cut, and a bar too narrow even for that cuts
/// the elapsed segment to whole cells so the row is not empty.
fn fitClock(view: View, room: i32, buf: []u8) []const u8 {
    const cell: i32 = @intCast(font.cell_w);
    const cells: usize = @intCast(@divFloor(room, cell));
    const sep: usize = 3; // " | "
    const elapsed = view.clock;
    if (elapsed.len > cells) return font.fit(elapsed, @intCast(room));
    var stream: std.Io.Writer = .fixed(buf);
    if (view.note) |note| {
        if (elapsed.len + sep + note.len <= cells) {
            stream.print("{s} | {s}", .{ elapsed, note }) catch return elapsed;
            return stream.buffered();
        }
        if (view.command_refused and elapsed.len + 2 <= cells) {
            stream.print("{s} !", .{elapsed}) catch return elapsed;
            return stream.buffered();
        }
        return elapsed;
    }
    if (view.clock_date == null) if (view.clock_speed) |speed| {
        if (elapsed.len + sep + speed.len <= cells) {
            stream.print("{s} | {s}", .{ elapsed, speed }) catch return elapsed;
            return stream.buffered();
        }
    };
    if (view.clock_date) |date| {
        if (view.clock_speed) |speed| {
            if (date.len + sep + elapsed.len + sep + speed.len <= cells) {
                stream.print("{s} | {s} | {s}", .{ date, elapsed, speed }) catch return elapsed;
                return stream.buffered();
            }
        }
        if (date.len + sep + elapsed.len <= cells) {
            stream.print("{s} | {s}", .{ date, elapsed }) catch return elapsed;
            return stream.buffered();
        }
    }
    return elapsed;
}

fn fieldBox(table: *const widget.types.Paint, theme: *const Theme, area: Rect, view: View) void {
    if (area.empty()) return;
    fillArea(table, area, theme.well);
    outline(table, area, if (view.field_refused) theme.bad else if (view.editing) theme.accent else theme.control_border);
    const shown = view.field;
    label(table, area, shown, theme.ink, theme.well);
    if (!view.editing) {
        const caption = "Speed";
        const left = area.x + area.w - pad - @as(i32, @intCast(font.textWidth(caption.len)));
        if (left >= area.x + 2 * pad + @as(i32, @intCast(font.textWidth(shown.len))))
            drawText(table, left, area.y + draw_list.centre(area.h, font.glyph_h), caption, theme.muted, theme.well);
        return;
    }
    const caret_x = area.x + pad + @as(i32, @intCast(font.textWidth(shown.len)));
    fillArea(table, .{ .x = caret_x, .y = area.y + 2, .w = 1, .h = area.h - 4 }, theme.ink);
}

fn outline(table: *const widget.types.Paint, area: Rect, color: Color) void {
    fillArea(table, .{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y + area.h - 1, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, color);
    fillArea(table, .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h }, color);
}

/// `line` from a pad in, centred down `area`, cut to whole cells inside it;
/// `bg` is the fill already under the text's cell.
fn label(table: *const widget.types.Paint, area: Rect, line: []const u8, color: Color, bg: Color) void {
    const room = area.w - 2 * pad;
    if (room <= 0) return;
    const shown = font.fit(line, @intCast(room));
    const top = area.y + draw_list.centre(area.h, font.glyph_h);
    drawText(table, area.x + pad, top, shown, color, bg);
}

/// The control under (`x`, `y`) in `bar`, or null for the gaps and the clock.
pub fn hit(bar: Rect, x: i32, y: i32) ?Control {
    const layout = Layout.of(bar);
    for ([_]Control{ .run, .pause, .step, .over, .out, .field }) |control| {
        if (layout.rect(control).contains(x, y)) return control;
    }
    return null;
}
