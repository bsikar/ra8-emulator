//! Drawing and rasterization for src/interfaces/gui/ui/time_bar.zig (RA8EMU-807).
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;
const speed_field = @import("../speed_field.zig");
const time_bar = @import("time_bar.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Control = time_bar.Control;
const Layout = time_bar.Layout;
const View = time_bar.View;

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, bar: Rect, view: View) void {
    if (bar.empty()) return;
    table.push_clip.?(table.user, bar.x, bar.y, bar.w, bar.h);
    fillArea(table, bar, theme.ribbon_bg);
    fillArea(table, .{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, theme.border);
    const layout = Layout.of(bar);
    for ([_]Control{ .run, .pause, .step, .over, .out }) |control| {
        button(table, theme, layout.rect(control), control, view);
    }
    fieldBox(table, theme, layout.field, view);
    seekBox(table, theme, layout.seek, view);
    clock(table, theme, layout.clock, view);
    table.pop_clip.?(table.user);
    if (view.open and !layout.field.empty()) dropdown(table, theme, layout.field, view);
}

fn fillArea(table: *const widget.types.Paint, r: Rect, color: Color) void {
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

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
    w.rect = .{ .x = x, .y = y, .w = @intCast(font.textWidth(text.len)), .h = @intCast(font.cell_h) };
    w.vt.?.render.?(&w);
}

fn lights(control: Control, view: View) bool {
    return switch (control) {
        .run => view.run_lit,
        .pause => view.pause_lit,
        .step, .over, .out, .field, .drop, .seek => false,
    };
}

fn button(paint: *const widget.types.Paint, theme: *const Theme, area: Rect, control: Control, view: View) void {
    if (area.empty()) return;
    const enabled = switch (control) {
        .run => view.run_enabled,
        .pause => view.pause_enabled,
        .step => view.step_enabled,
        .over => view.over_enabled,
        .out => view.out_enabled,
        .field, .drop, .seek => true,
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
            .field, .drop, .seek => "",
        },
        .on_press = null,
        .fg = word(if (on) theme.background else if (!enabled) theme.muted else theme.ink),
        .face = word(theme.face),
        .face_pressed = word(switch (control) {
            .run => theme.runLit(),
            .pause => theme.pauseLit(),
            .step, .over, .out => theme.step_active,
            .field, .drop, .seek => theme.accent,
        }),
        .border = word(if (on) switch (control) {
            .run => theme.good,
            .pause => theme.highlight,
            .step, .over, .out => theme.step_active,
            .field, .drop, .seek => theme.accent,
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

fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

fn clock(paint: *const widget.types.Paint, theme: *const Theme, area: Rect, view: View) void {
    const room = area.w - 2 * time_bar.pad;
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
    w.rect = .{ .x = area.x + time_bar.pad - down, .y = area.y, .w = area.w - (time_bar.pad - down), .h = area.h };
    w.vt.?.render.?(&w);
}

fn fitClock(view: View, room: i32, buf: []u8) []const u8 {
    const cell: i32 = @intCast(font.cell_w);
    const cells: usize = @intCast(@divFloor(room, cell));
    const sep: usize = 3;
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
    label(table, .{ .x = area.x, .y = area.y, .w = area.w - time_bar.drop_w, .h = area.h }, shown, theme.ink, theme.well);
    drawDropArrow(table, theme, time_bar.dropBox(area), view.open);
    if (!view.editing) {
        const caption = "Speed";
        const left = area.x + area.w - time_bar.drop_w - time_bar.pad - @as(i32, @intCast(font.textWidth(caption.len)));
        if (left >= area.x + 2 * time_bar.pad + @as(i32, @intCast(font.textWidth(shown.len))))
            drawText(table, left, area.y + draw_list.centre(area.h, font.glyph_h), caption, theme.muted, theme.well);
        return;
    }
    const caret_x = area.x + time_bar.pad + @as(i32, @intCast(font.textWidth(shown.len)));
    fillArea(table, .{ .x = caret_x, .y = area.y + 2, .w = 1, .h = area.h - 4 }, theme.ink);
}

fn seekBox(table: *const widget.types.Paint, theme: *const Theme, area: Rect, view: View) void {
    if (area.empty()) return;
    fillArea(table, area, theme.well);
    outline(table, area, if (view.seek_editing) theme.accent else theme.control_border);
    const shown = view.seek;
    label(table, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h }, shown, theme.ink, theme.well);
    if (!view.seek_editing) {
        const caption = "Seek";
        const left = area.x + area.w - time_bar.pad - @as(i32, @intCast(font.textWidth(caption.len)));
        if (left >= area.x + 2 * time_bar.pad + @as(i32, @intCast(font.textWidth(shown.len))))
            drawText(table, left, area.y + draw_list.centre(area.h, font.glyph_h), caption, theme.muted, theme.well);
        return;
    }
    const caret_x = area.x + time_bar.pad + @as(i32, @intCast(font.textWidth(shown.len)));
    fillArea(table, .{ .x = caret_x, .y = area.y + 2, .w = 1, .h = area.h - 4 }, theme.ink);
}

fn drawDropArrow(table: *const widget.types.Paint, theme: *const Theme, area: Rect, open: bool) void {
    if (area.empty()) return;
    const cx = area.x + @divTrunc(area.w, 2);
    const cy = area.y + @divTrunc(area.h - 3, 2);
    const color = if (open) theme.accent else theme.muted;
    const dy: i32 = if (open) 2 else 0;
    const dir: i32 = if (open) -1 else 1;
    fillArea(table, .{ .x = cx - 2, .y = cy + dy, .w = 5, .h = 1 }, color);
    fillArea(table, .{ .x = cx - 1, .y = cy + dy + dir, .w = 3, .h = 1 }, color);
    fillArea(table, .{ .x = cx, .y = cy + dy + 2 * dir, .w = 1, .h = 1 }, color);
}

fn dropdown(table: *const widget.types.Paint, theme: *const Theme, field: Rect, view: View) void {
    const box = time_bar.popover(field);
    fillArea(table, box, theme.well);
    outline(table, box, theme.border);
    for (speed_field.presets, 0..) |preset, index| {
        const item = time_bar.popoverRow(field, index);
        const active = view.applied != null and view.applied.? == preset.milli;
        if (active) fillArea(table, item, theme.band);
        const color = if (active) theme.highlight else theme.ink;
        const bg = if (active) theme.band else theme.well;
        drawText(table, item.x + time_bar.pad, item.y + draw_list.centre(item.h, font.glyph_h), preset.label, color, bg);
    }
}

fn outline(table: *const widget.types.Paint, area: Rect, color: Color) void {
    fillArea(table, .{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y + area.h - 1, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, color);
    fillArea(table, .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h }, color);
}

fn label(table: *const widget.types.Paint, area: Rect, line: []const u8, color: Color, bg: Color) void {
    const room = area.w - 2 * time_bar.pad;
    if (room <= 0) return;
    const shown = font.fit(line, @intCast(room));
    const top = area.y + draw_list.centre(area.h, font.glyph_h);
    drawText(table, area.x + time_bar.pad, top, shown, color, bg);
}
