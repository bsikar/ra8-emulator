//! The board pane (RA8EMU-813): the board as one block of draw-list
//! commands. An outline of the board holds the panel image the shell's board
//! feed builds from lcd_dirty (RA8EMU-790), the user LEDs lit from the
//! session's led_changed events (RA8EMU-811) and the user switches as hit
//! rects. The pane draws exactly the parts the session reports through
//! board_parts (RA8EMU-1151), so any LED or switch count and any panel
//! aspect lays out and lights the same way, and the pane carries no board
//! knowledge of its own. Layout is a pure function of the area and the
//! parts; the panel image keeps its own aspect inside its slot, and before
//! (or without) a frame the slot is fitted to the reported panel. The shell
//! (RA8EMU-201) places the pane.
//! gui/board.capture.zig folds the session's events into `Leds`; this pane
//! never imports the session or the chip.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const fit = @import("fit.zig");
const Theme = @import("colors.zig").Theme;
const unseen = @import("colors.zig").unseen;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// Below this the board would be unreadable, so nothing is drawn.
pub const min_w: i32 = 160;
pub const min_h: i32 = 100;
/// The board outline keeps a 3:2 shape.
const shape_w: u32 = 3;
const shape_h: u32 = 2;
const pad: i32 = 4;

/// The most LEDs, switches and label bytes the pane keeps, the shell's
/// copy-off-the-wire storage.
pub const max_leds: usize = 8;
pub const max_switches: usize = 8;
pub const name_max: usize = 24;

/// The panel profile whose shape the pane draws the panel at before (or
/// without) a frame (RA8EMU-1150), as the session reports it (RA8EMU-1151).
pub const Profile = struct {
    width: u32 = 0,
    height: u32 = 0,
};

/// One LED's lamp colour and label, as the session reports it.
pub const Led = struct {
    rgb565: u16,
    name: []const u8,
};

/// The board's parts, as the session reports them through board_parts
/// (RA8EMU-1151): the LEDs in the chip's led_changed order, the switch
/// labels in the board's switch order, and the panel profile the pre-frame
/// slot fits. Width and height 0 (no panel or unknown) keep the raw slot
/// shape.
pub const Parts = struct {
    leds: []const Led = &.{},
    switch_names: []const []const u8 = &.{},
    panel: Profile = .{},
};

/// What the LEDs show; gui/board.capture.zig folds the session's
/// led_changed events into it.
pub const Leds = struct {
    on: [max_leds]bool = @splat(false),
};

/// Where each part sits. Every rect is empty when the area is too small.
pub const Layout = struct {
    board: Rect,
    panel: Rect,
    led_count: usize,
    switch_count: usize,
    leds: [max_leds]Rect,
    switches: [max_switches]Rect,

    pub fn of(area: Rect, parts: Parts) Layout {
        const led_count = @min(parts.leds.len, max_leds);
        const switch_count = @min(parts.switch_names.len, max_switches);
        var layout: Layout = .{ .board = none(area), .panel = none(area), .led_count = led_count, .switch_count = switch_count, .leds = @splat(none(area)), .switches = @splat(none(area)) };
        if (area.w < min_w or area.h < min_h) return layout;
        const inner: Rect = .{ .x = area.x + pad, .y = area.y + pad, .w = area.w - 2 * pad, .h = area.h - 2 * pad };
        const board = fit.fitIn(inner, shape_w, shape_h);
        const margin = @max(pad, @divTrunc(board.w, 24));
        const column = @divTrunc(board.w, 4);
        layout.board = board;
        layout.panel = .{ .x = board.x + margin, .y = board.y + margin, .w = board.w - column - 2 * margin, .h = board.h - 2 * margin };
        if (parts.panel.width > 0 and parts.panel.height > 0) layout.panel = fit.fitIn(layout.panel, parts.panel.width, parts.panel.height);
        // The LEDs and switches share the column, each with its label under it.
        const label_h = @as(i32, font.cell_h) + pad;
        const side_parts = led_count + switch_count;
        const room = if (side_parts == 0) @as(i32, board.h) else @divTrunc(board.h - 2 * margin, @as(i32, @intCast(side_parts))) - label_h;
        const side = @max(4, @min(@min(@divTrunc(column, 4), @divTrunc(board.h, 10)), room));
        const step = side + label_h;
        for (layout.leds[0..led_count], 0..) |*led, index| {
            led.* = .{ .x = board.x + board.w - column + @divTrunc(column - side, 2) - margin / 2, .y = board.y + margin + @as(i32, @intCast(index)) * step, .w = side, .h = side };
        }
        const button_w = @min(column - 2 * margin, 2 * side);
        for (layout.switches[0..switch_count], 0..) |*button, index| {
            // Switches sit at the bottom, but never above the slot under the last LED.
            const from_bottom: i32 = @intCast(switch_count - index);
            const below_leds = board.y + margin + @as(i32, @intCast(led_count + index)) * step;
            const y = @max(below_leds, board.y + board.h - margin - from_bottom * step);
            button.* = .{ .x = board.x + board.w - column + @divTrunc(column - button_w, 2) - margin / 2, .y = y, .w = button_w, .h = side };
        }
        return layout;
    }

    /// The switch a click at (x, y) lands on, if any.
    pub fn hit(self: Layout, x: i32, y: i32) ?usize {
        for (self.switches[0..self.switch_count], 0..) |button, index| if (button.contains(x, y)) return index;
        return null;
    }

    fn none(area: Rect) Rect {
        return .{ .x = area.x, .y = area.y, .w = 0, .h = 0 };
    }
};

/// What one frame of the pane shows; `panel` is null until the board feed
/// has a frame.
pub const View = struct {
    leds: *const Leds,
    panel: ?draw_list.Image = null,
    /// The panel part that changed since the last draw (RA8EMU-823).
    dirty: draw_list.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The switch held down by the pointer (RA8EMU-814), drawn pressed.
    pressed: ?usize = null,
    /// Frames passed over since the last present (RA8EMU-824), drawn in the
    /// panel's top-right corner.
    skipped: u64 = 0,
};

/// Paints the pane into `area`; an area under the minimum draws nothing.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, view: View, parts: Parts) !void {
    const layout = Layout.of(area, parts);
    if (layout.board.empty()) return;
    try list.fill(area, theme.background);
    try list.pushClip(area);
    defer list.popClip();
    try list.fill(layout.board, theme.border);
    try list.fill(inset(layout.board), theme.well);
    const image = view.panel orelse return drawParts(list, theme, layout, view, parts, unseen);
    try list.fill(layout.panel, theme.background);
    const shown = fit.fitIn(layout.panel, image.width, image.height);
    try list.panel(shown, image, view.dirty, !wholeScale(shown, image.width, image.height));
    if (view.skipped > 0) try cornerSkipped(list, shown, view.skipped, theme);
    try drawParts(list, theme, layout, view, parts, null);
}

/// Whether `shown` is the panel at a whole-number scale, drawn nearest so
/// its pixels stay crisp (RA8EMU-965); any other scale is filtered.
pub fn wholeScale(shown: Rect, width: u32, height: u32) bool {
    if (shown.w <= 0 or shown.h <= 0 or width == 0 or height == 0) return true;
    const w: u32 = @intCast(shown.w);
    const h: u32 = @intCast(shown.h);
    return w % width == 0 and h % height == 0 and w / width == h / height;
}

/// The empty panel slot (when `blank` is set), the LEDs and the switches.
fn drawParts(list: *draw_list.DrawList, theme: *const Theme, layout: Layout, view: View, parts: Parts, blank: ?Color) !void {
    if (blank) |color| try list.fill(layout.panel, color);
    for (layout.leds[0..layout.led_count], 0..) |led, index| {
        try list.fill(led, theme.led_bezel);
        const inner = inset(led);
        const on = view.leds.on[index];
        try list.fill(inner, if (on) lampOf(parts.leds[index].rgb565) else theme.led_off);
        if (on and inner.w >= 8 and inner.h >= 8) {
            // Optical specular highlight on active LED diffuser, only where it
            // stays clear of the lamp's centre.
            try list.fill(.{ .x = inner.x + 2, .y = inner.y + 2, .w = 2, .h = 2 }, theme.led_specular);
        }
        try label(list, led, parts.leds[index].name, theme.muted);
    }
    for (layout.switches[0..layout.switch_count], 0..) |button, index| {
        const is_pressed = view.pressed == index;
        try list.fill(button, if (is_pressed) theme.accent else theme.control_border);
        try list.fill(inset(button), if (is_pressed) theme.pressed_face else theme.face);
        try label(list, button, parts.switch_names[index], if (is_pressed) theme.accent else theme.ink);
    }
}

/// The skipped count in the panel's top-right corner (RA8EMU-824).
fn cornerSkipped(list: *draw_list.DrawList, panel: Rect, skipped: u64, theme: *const Theme) !void {
    var text: [24]u8 = undefined;
    const shown = std.fmt.bufPrint(&text, "skipped {d}", .{skipped}) catch return;
    const w: i32 = @intCast(font.textWidth(shown.len));
    try font.draw(list, panel.x + panel.w - w - 4, panel.y + 4, shown, theme.ink);
}

/// An LED's lit colour from the board's RGB565 word.
pub fn lampOf(rgb565: u16) Color {
    const r: u8 = @intCast((rgb565 >> 11) & 0x1F);
    const g: u8 = @intCast((rgb565 >> 5) & 0x3F);
    const b: u8 = @intCast(rgb565 & 0x1F);
    return Color.rgb(r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2);
}

fn inset(area: Rect) Rect {
    return .{ .x = area.x + 1, .y = area.y + 1, .w = @max(0, area.w - 2), .h = @max(0, area.h - 2) };
}

/// A name centred under `area`.
fn label(list: *draw_list.DrawList, area: Rect, text: []const u8, color: Color) !void {
    const w: i32 = @intCast(font.textWidth(text.len));
    try font.draw(list, area.x + draw_list.centre(area.w, w), area.y + area.h + 2, text, color);
}
