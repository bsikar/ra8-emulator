//! Draws the camera panel and turns clicks on it into picks and answers
//! (RA8EMU-500). It only reads and changes a `camera_panel.Panel`; the
//! shell sends each pick to the session, which opens the source
//! (shell_camera.zig).
//!
//! A row of one button per source, the active one ringed; a dot that is
//! red while the webcam is the source; and, while the webcam permission is
//! being asked, a dialog of Allow once, Always for this project and Cancel.
//! Each button has its own colour and a short label in the built-in font
//! (RA8EMU-677). While Always stands, the dialog row holds one button that
//! takes it back (RA8EMU-1124), clear of the dialog's own three so a second
//! click on Always cannot land on it.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const camera_panel = @import("../camera/panel.zig");
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;
const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Panel = camera_panel.Panel;
const Kind = camera_panel.Kind;
const Answer = camera_panel.Answer;

pub const button: i32 = 24;
pub const gap: i32 = 4;
pub const dot: i32 = 8;

/// Each source's button colour.
pub fn colorOf(theme: *const Theme, kind: Kind) Color {
    return switch (kind) {
        .gradient => theme.muted,
        .image => theme.hue.blue,
        .video => theme.hue.purple,
        .pipe => theme.hue.green,
        .webcam => theme.hue.yellow,
    };
}

/// Each source's button label, three cells at most.
pub fn labelOf(kind: Kind) []const u8 {
    return switch (kind) {
        .gradient => "GRD",
        .image => "IMG",
        .video => "VID",
        .pipe => "PIP",
        .webcam => "CAM",
    };
}

/// Each answer's button label.
pub fn answerLabel(reply: Answer) []const u8 {
    return switch (reply) {
        .allow_once => "ONE",
        .always => "ALW",
        .cancel => "NO",
    };
}

/// The label and colour of the button that takes Always back.
pub const withdraw_label = "FORGET ALWAYS";

/// Label ink that reads on `fill`: the dark background on light fills,
/// the light ring colour on dark ones.
pub fn inkOn(theme: *const Theme, fill: Color) Color {
    const luma = @as(u32, fill.r) * 299 + @as(u32, fill.g) * 587 + @as(u32, fill.b) * 114;
    return if (luma > 128 * 1000) theme.preview else theme.ink;
}

/// Each answer's button colour.
pub fn answerColor(theme: *const Theme, reply: Answer) Color {
    return switch (reply) {
        .allow_once => theme.hue.green,
        .always => theme.hue.blue,
        .cancel => theme.hue.red,
    };
}

/// Where everything sits, from the panel's top-left corner.
pub const Layout = struct {
    x: i32,
    y: i32,

    const kinds = std.enums.values(Kind);

    /// The whole panel: the source row over the dialog row.
    pub fn area(self: Layout) Rect {
        const sources = @as(i32, @intCast(kinds.len + 1)) * (button + gap) + gap;
        const answers: i32 = @intCast(std.enums.values(Answer).len);
        const label: i32 = @intCast(font.textWidth(withdraw_label.len) + 4);
        const row = gap + answers * (button + gap) + label + gap;
        return .{ .x = self.x, .y = self.y, .w = @max(sources, row), .h = 2 * (button + gap) + gap };
    }

    pub fn source(self: Layout, kind: Kind) Rect {
        const at: i32 = @intCast(@backingInt(kind));
        return .{ .x = self.x + gap + at * (button + gap), .y = self.y + gap, .w = button, .h = button };
    }

    pub fn indicator(self: Layout) Rect {
        const at: i32 = @intCast(kinds.len);
        const x = self.x + gap + at * (button + gap) + @divTrunc(button - dot, 2);
        return .{ .x = x, .y = self.y + gap + @divTrunc(button - dot, 2), .w = dot, .h = dot };
    }

    pub fn dialog(self: Layout, reply: Answer) Rect {
        const at: i32 = @intCast(@backingInt(reply));
        const y = self.y + 2 * gap + button;
        return .{ .x = self.x + gap + at * (button + gap), .y = y, .w = button, .h = button };
    }

    /// The button that takes Always back: the rest of the dialog row,
    /// after the last answer's slot.
    pub fn withdraw(self: Layout) Rect {
        const at: i32 = @intCast(std.enums.values(Answer).len);
        const left = gap + at * (button + gap);
        return .{ .x = self.x + left, .y = self.y + 2 * gap + button, .w = self.area().w - left - gap, .h = button };
    }
};

/// Appends the panel as it stands to `list`.
pub fn draw(table: *const widget.types.Paint, theme: *const Theme, layout: Layout, panel: Panel) !void {
    fillArea(table, layout.area(), word(theme.preview));
    for (Layout.kinds) |kind| {
        const at = layout.source(kind);
        if (kind == panel.active) {
            fillArea(table, .{ .x = at.x - 2, .y = at.y - 2, .w = at.w + 4, .h = at.h + 4 }, word(theme.ink));
        }
        fillArea(table, at, word(colorOf(theme, kind)));
        drawCentred(table, at, labelOf(kind), word(inkOn(theme, colorOf(theme, kind))), word(colorOf(theme, kind)));
    }
    fillArea(table, layout.indicator(), word(if (panel.cameraOn()) theme.recording else theme.border));
    if (panel.always) {
        fillArea(table, layout.withdraw(), word(theme.hue.blue));
        drawCentred(table, layout.withdraw(), withdraw_label, word(inkOn(theme, theme.hue.blue)), word(theme.hue.blue));
    }
    if (!panel.asking) return;
    for (std.enums.values(Answer)) |reply| {
        fillArea(table, layout.dialog(reply), word(answerColor(theme, reply)));
        drawCentred(table, layout.dialog(reply), answerLabel(reply), word(inkOn(theme, answerColor(theme, reply))), word(answerColor(theme, reply)));
    }
}

/// Applies a click at (`x`, `y`) to `panel`. While the dialog is open only
/// its buttons and the source row answer; a click anywhere else is not the
/// panel's. While Always stands, its button takes it back. Returns whether
/// the panel took the click.
pub fn click(panel: *Panel, layout: Layout, x: i32, y: i32) bool {
    if (panel.asking) {
        for (std.enums.values(Answer)) |reply| {
            if (layout.dialog(reply).contains(x, y)) {
                panel.answer(reply);
                return true;
            }
        }
    }
    if (panel.always and layout.withdraw().contains(x, y)) {
        panel.withdraw();
        return true;
    }
    for (Layout.kinds) |kind| {
        if (layout.source(kind).contains(x, y)) {
            panel.pick(kind);
            return true;
        }
    }
    return layout.area().contains(x, y);
}

/// `area` filled with `color` through the shared Paint table.
fn fillArea(table: *const widget.types.Paint, area: Rect, color: u32) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, color);
}

/// `text`, cut to whole cells that fit with a pixel spare each side, centred
/// in `area` through the shared Paint table; `bg` is the fill already under
/// the text's cell.
fn drawCentred(table: *const widget.types.Paint, area: Rect, text: []const u8, fg: u32, bg: u32) void {
    const shown = font.fit(text, @intCast(@max(area.w - 2, 0)));
    if (shown.len == 0) return;
    const x = area.x + draw_list.centre(area.w, @intCast(font.textWidth(shown.len)));
    const y = area.y + draw_list.centre(area.h, font.glyph_h);
    drawText(table, x, y, shown, fg, bg);
}

fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [64]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = fg,
        .bg = bg,
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

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
