//! The board pane (RA8EMU-813): the EK-RA8D2 as one block of draw-list
//! commands. An outline of the board holds the panel image the shell's board
//! feed builds from lcd_dirty (RA8EMU-790), the three user LEDs lit from the
//! session's led_changed events (RA8EMU-811) and the two user switches as hit
//! rects. Layout is a pure function of the area; the panel image keeps its
//! own aspect inside its slot. The shell (RA8EMU-201) places the pane.
const std = @import("std");
const proto = @import("../interfaces/rpc/session_rpc.zig");
const gpio = @import("../periph/gpio/gpio.zig");
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const shell_board = @import("shell_board.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const pcb = Color.rgb(0x1B, 0x1F, 0x24);
pub const border = Color.rgb(0x4A, 0x51, 0x5C);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const muted = Color.rgb(0x9A, 0xA5, 0xB4);
pub const face = Color.rgb(0x2C, 0x31, 0x3A);
pub const dark = Color.rgb(0x00, 0x00, 0x00);
pub const off = Color.rgb(0x3A, 0x40, 0x4A);

/// Below this the board would be unreadable, so nothing is drawn.
pub const min_w: i32 = 160;
pub const min_h: i32 = 100;
/// The board outline keeps a 3:2 shape.
const shape_w: u32 = 3;
const shape_h: u32 = 2;
const pad: i32 = 4;

pub const switch_count: usize = 2;
pub const switch_names = [switch_count][]const u8{ "SW1", "SW2" };
pub const led_names = [gpio.led_count][]const u8{ "LED1", "LED2", "LED3" };

/// What the LEDs show, folded from the session's led_changed events.
pub const Leds = struct {
    on: [gpio.led_count]bool = @splat(false),

    /// Takes one session event; anything but a known LED's change is ignored.
    pub fn observe(self: *Leds, event: proto.SessionEvent) void {
        if (event.kind != .led_changed) return;
        const index = event.address & 0xFF;
        if (index >= gpio.led_count) return;
        self.on[index] = event.address & 0x100 != 0;
    }
};

/// Where each part sits. Every rect is empty when the area is too small.
pub const Layout = struct {
    board: Rect,
    panel: Rect,
    leds: [gpio.led_count]Rect,
    switches: [switch_count]Rect,

    pub fn of(area: Rect) Layout {
        var layout: Layout = .{ .board = none(area), .panel = none(area), .leds = @splat(none(area)), .switches = @splat(none(area)) };
        if (area.w < min_w or area.h < min_h) return layout;
        const inner: Rect = .{ .x = area.x + pad, .y = area.y + pad, .w = area.w - 2 * pad, .h = area.h - 2 * pad };
        const board = shell_board.fitIn(inner, shape_w, shape_h);
        const margin = @max(pad, @divTrunc(board.w, 24));
        const column = @divTrunc(board.w, 4);
        layout.board = board;
        layout.panel = .{ .x = board.x + margin, .y = board.y + margin, .w = board.w - column - 2 * margin, .h = board.h - 2 * margin };
        const side = @min(@divTrunc(column, 4), @divTrunc(board.h, 10));
        const left = board.x + board.w - column + @divTrunc(column - side, 2) - margin / 2;
        const step = side + @as(i32, font.cell_h) + pad;
        for (&layout.leds, 0..) |*led, index| {
            led.* = .{ .x = left, .y = board.y + margin + @as(i32, @intCast(index)) * step, .w = side, .h = side };
        }
        const button_w = @min(column - 2 * margin, 2 * side);
        const button_x = board.x + board.w - column + @divTrunc(column - button_w, 2) - margin / 2;
        for (&layout.switches, 0..) |*button, index| {
            const from_bottom: i32 = @intCast(switch_count - index);
            button.* = .{ .x = button_x, .y = board.y + board.h - margin - from_bottom * step, .w = button_w, .h = side };
        }
        return layout;
    }

    /// The switch a click at (x, y) lands on, if any.
    pub fn hit(self: Layout, x: i32, y: i32) ?usize {
        for (self.switches, 0..) |button, index| if (button.contains(x, y)) return index;
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
};

/// Paints the pane into `area`; an area under the minimum draws nothing.
pub fn draw(list: *draw_list.DrawList, area: Rect, view: View) !void {
    const layout = Layout.of(area);
    if (layout.board.empty()) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    try list.fill(layout.board, border);
    try list.fill(inset(layout.board), pcb);
    try list.fill(layout.panel, dark);
    if (view.panel) |image| try list.image(shell_board.fitIn(layout.panel, image.width, image.height), image);
    for (layout.leds, 0..) |led, index| {
        try list.fill(led, if (view.leds.on[index]) lampOf(gpio.leds[index].rgb565) else off);
        try label(list, led, led_names[index], muted);
    }
    for (layout.switches, 0..) |button, index| {
        try list.fill(button, border);
        try list.fill(inset(button), face);
        try label(list, button, switch_names[index], ink);
    }
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
    try font.draw(list, area.x + @divTrunc(area.w - w, 2), area.y + area.h + 2, text, color);
}
