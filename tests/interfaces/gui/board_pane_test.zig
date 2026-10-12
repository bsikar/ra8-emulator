//! Host tests for the board pane (RA8EMU-813): where the board, panel, LEDs
//! and switches sit at two sizes, a too-small area that draws nothing, LED
//! state folded from session events, switch hits, and a pinned CPU-backend
//! golden with LED1 on and the others off. The parts come from the session's
//! board_parts answer (RA8EMU-1151); the chip match lives with the wire.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.board_pane;
const capture = gui_app.board.capture;
const proto = ra8.rpc.session.rpc;
const Rect = draw_list.Rect;
const Color = draw_list.Color;

/// The EK-RA8D2's parts, as the session's board_parts answer reports them:
/// three user LEDs, two user switches, the ER-TFT070-6 glass.
const ek_ra8d2: pane.Parts = .{
    .leds = &.{
        .{ .rgb565 = 0x001F, .name = "LED1 BLUE" },
        .{ .rgb565 = 0x07E0, .name = "LED2 GREEN" },
        .{ .rgb565 = 0xF800, .name = "LED3 RED" },
    },
    .switch_names = &.{ "SW1", "SW2" },
    .panel = .{ .width = 1024, .height = 600 },
};

fn inside(outer: Rect, inner: Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h;
}

fn overlap(a: Rect, b: Rect) bool {
    return !a.intersect(b).empty();
}

fn checkLayout(area: Rect, parts: pane.Parts) !void {
    const layout = pane.Layout.of(area, parts);
    try std.testing.expect(!layout.board.empty());
    try std.testing.expect(inside(area, layout.board));
    try std.testing.expectEqual(@as(i64, layout.board.w) * 2, @as(i64, layout.board.h) * 3);
    try std.testing.expect(inside(layout.board, layout.panel));
    for (layout.leds[0..layout.led_count]) |led| {
        try std.testing.expect(!led.empty() and inside(layout.board, led) and !overlap(led, layout.panel));
    }
    for (layout.switches[0..layout.switch_count], 0..) |button, index| {
        try std.testing.expect(!button.empty() and inside(layout.board, button) and !overlap(button, layout.panel));
        for (layout.leds[0..layout.led_count]) |led| try std.testing.expect(!overlap(button, led));
        try std.testing.expectEqual(@as(?usize, index), layout.hit(button.x + 1, button.y + 1));
    }
    try std.testing.expectEqual(@as(?usize, null), layout.hit(layout.panel.x + 1, layout.panel.y + 1));
}

test "the board keeps its shape and every part sits inside it at two sizes" {
    try checkLayout(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, ek_ra8d2);
    try checkLayout(.{ .x = 10, .y = 20, .w = 900, .h = 400 }, ek_ra8d2);
}

test "the LEDs stack down the column and the switches sit at the bottom" {
    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, ek_ra8d2);
    try std.testing.expect(layout.leds[0].y < layout.leds[1].y and layout.leds[1].y < layout.leds[2].y);
    try std.testing.expect(layout.switches[0].y < layout.switches[1].y);
}

test "an area under the minimum lays out nothing and draws nothing" {
    const area: Rect = .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = 200 };
    const layout = pane.Layout.of(area, ek_ra8d2);
    try std.testing.expect(layout.board.empty() and layout.panel.empty());
    var list = draw_list.DrawList.init(std.testing.allocator, 200, 200);
    defer list.deinit();
    const leds: pane.Leds = .{};
    try pane.draw(&list, dark, area, .{ .leds = &leds }, ek_ra8d2);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "LEDs follow led_changed events and ignore everything else" {
    var leds: pane.Leds = .{};
    const count = ek_ra8d2.leds.len;
    capture.observe(&leds, count, .{ .core = .cpu0, .kind = .led_changed, .address = 0x100 });
    capture.observe(&leds, count, .{ .core = .cpu0, .kind = .led_changed, .address = 0x102 });
    capture.observe(&leds, count, .{ .core = .cpu0, .kind = .led_changed, .address = 0x002 });
    capture.observe(&leds, count, .{ .core = .cpu0, .kind = .led_changed, .address = 0x107 });
    capture.observe(&leds, count, .{ .core = .cpu0, .kind = .breakpoint_set, .address = 0x101 });
    try std.testing.expectEqualSlices(bool, &.{ true, false, false }, leds.on[0..count]);
}

test "a change past the reported LED count is not an LED here" {
    var leds: pane.Leds = .{};
    capture.observe(&leds, 2, .{ .core = .cpu0, .kind = .led_changed, .address = 0x102 });
    try std.testing.expectEqual(@as(pane.Leds, .{}), leds);
}

test "a lit LED takes the board's colour" {
    try std.testing.expectEqual(Color.rgb(0, 0, 0xFF), pane.lampOf(0x001F));
    try std.testing.expectEqual(Color.rgb(0, 0xFF, 0), pane.lampOf(0x07E0));
    try std.testing.expectEqual(Color.rgb(0xFF, 0, 0), pane.lampOf(0xF800));
}

/// The board pane at 480x320 with LED1 on over a grey ramp panel, in `theme`.
// TEMPORARY golden dump, never committed.

fn boardDigest(theme: *const gui_app.colors.Theme) !u64 {
    const w = 480;
    const h = 320;
    var list = draw_list.DrawList.init(std.testing.allocator, w, h);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, w, h);
    defer frame.deinit(std.testing.allocator);
    var pixels: [64 * 36]Color = undefined;
    for (&pixels, 0..) |*pixel, index| {
        const shade: u8 = @intCast((index % 64) * 4);
        pixel.* = Color.rgb(shade, shade, shade);
    }
    var leds: pane.Leds = .{};
    capture.observe(&leds, ek_ra8d2.leds.len, .{ .core = .cpu0, .kind = .led_changed, .address = 0x100 });
    try pane.draw(&list, theme, .{ .x = 0, .y = 0, .w = w, .h = h }, .{ .leds = &leds, .panel = .{ .width = 64, .height = 36, .pixels = &pixels } }, ek_ra8d2);
    raster.draw(&frame, &list, font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "the board pane frame with LED1 on is pinned" {
    try std.testing.expectEqual(@as(u64, 12092915054774599063), try boardDigest(dark));
}

test "in the light palette the board pane frame is pinned to its own golden" {
    try std.testing.expectEqual(@as(u64, 6007499528918230181), try boardDigest(light));
}

/// The board pane frame with the skipped count in the panel's corner
/// (RA8EMU-824).
fn skippedDigest(theme: *const gui_app.colors.Theme) !u64 {
    const w = 480;
    const h = 320;
    var list = draw_list.DrawList.init(std.testing.allocator, w, h);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, w, h);
    defer frame.deinit(std.testing.allocator);
    var pixels: [64 * 36]Color = undefined;
    for (&pixels, 0..) |*pixel, index| {
        const shade: u8 = @intCast((index % 64) * 4);
        pixel.* = Color.rgb(shade, shade, shade);
    }
    var leds: pane.Leds = .{};
    capture.observe(&leds, ek_ra8d2.leds.len, .{ .core = .cpu0, .kind = .led_changed, .address = 0x100 });
    try pane.draw(&list, theme, .{ .x = 0, .y = 0, .w = w, .h = h }, .{ .leds = &leds, .panel = .{ .width = 64, .height = 36, .pixels = &pixels }, .skipped = 11 }, ek_ra8d2);
    raster.draw(&frame, &list, font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "the skipped count in the panel's corner is pinned" {
    try std.testing.expectEqual(@as(u64, 7690866633352112188), try skippedDigest(dark));
}

/// The board pane with a dirty panel sub-rect, at `area`'s scale.
fn dirtyDigest(theme: *const gui_app.colors.Theme, area: Rect) !u64 {
    var list = draw_list.DrawList.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer frame.deinit(std.testing.allocator);
    var pixels: [64 * 36]Color = undefined;
    for (&pixels, 0..) |*pixel, index| {
        const shade: u8 = @intCast((index % 64) * 4);
        pixel.* = Color.rgb(shade, shade, shade);
    }
    var leds: pane.Leds = .{};
    try pane.draw(&list, theme, area, .{ .leds = &leds, .panel = .{ .width = 64, .height = 36, .pixels = &pixels }, .dirty = .{ .x = 16, .y = 8, .w = 32, .h = 16 } }, ek_ra8d2);
    raster.draw(&frame, &list, font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "the pane with a dirty panel sub-rect is pinned at two scales" {
    try std.testing.expectEqual(@as(u64, 17365043600110254968), try dirtyDigest(dark, .{ .x = 0, .y = 0, .w = 480, .h = 320 }));
    try std.testing.expectEqual(@as(u64, 4734691168728858111), try dirtyDigest(dark, .{ .x = 0, .y = 0, .w = 900, .h = 400 }));
}

test "the panel slot keeps the loaded profile's aspect before a frame" {
    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, ek_ra8d2);
    try std.testing.expect(!layout.panel.empty());
    try std.testing.expect(@abs(@as(i64, layout.panel.w) * 600 - @as(i64, layout.panel.h) * 1024) <= 1024);
    try std.testing.expect(inside(layout.board, layout.panel));
}

test "the panel slot keeps an alternate profile's aspect" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = 320 };
    const small = pane.Layout.of(area, .{ .panel = .{ .width = 480, .height = 272 } }).panel;
    try std.testing.expect(@abs(@as(i64, small.w) * 272 - @as(i64, small.h) * 480) <= 480);
    const wide = pane.Layout.of(area, .{ .panel = .{ .width = 800, .height = 480 } }).panel;
    try std.testing.expect(@abs(@as(i64, wide.w) * 480 - @as(i64, wide.h) * 800) <= 800);
}

test "the panel slot keeps a portrait glass' aspect" {
    const slot = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, .{ .panel = .{ .width = 1072, .height = 1448 } }).panel;
    try std.testing.expect(slot.h > slot.w);
    try std.testing.expect(@abs(@as(i64, slot.w) * 1448 - @as(i64, slot.h) * 1072) <= 1448);
}

test "an unknown profile keeps the raw slot" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = 320 };
    const raw = pane.Layout.of(area, .{}).panel;
    const known = pane.Layout.of(area, ek_ra8d2).panel;
    try std.testing.expect(!raw.empty() and !known.empty());
    try std.testing.expect(inside(raw, known));
}

test "a board with no panel lays the parts out and draws the raw slot" {
    const bare: pane.Parts = .{ .leds = ek_ra8d2.leds, .switch_names = ek_ra8d2.switch_names };
    try checkLayout(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, bare);
    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, bare);
    const known = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, ek_ra8d2).panel;
    try std.testing.expect(!layout.panel.empty() and !known.empty());
    try std.testing.expect(inside(layout.panel, known));
}

test "a board with other counts lays every part out" {
    var leds: [pane.max_leds]pane.Led = undefined;
    for (&leds, 0..) |*led, index| led.* = .{ .rgb565 = @intCast(index), .name = "L" };
    var switches: [5][]const u8 = @splat("SW");
    const many: pane.Parts = .{ .leds = &leds, .switch_names = &switches, .panel = .{ .width = 480, .height = 272 } };
    try checkLayout(.{ .x = 0, .y = 0, .w = 900, .h = 400 }, many);
    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 900, .h = 400 }, many);
    try std.testing.expectEqual(@as(usize, 5), layout.switch_count);
    const lone: pane.Parts = .{ .leds = ek_ra8d2.leds[0..1] };
    const one = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, lone);
    try std.testing.expectEqual(@as(usize, 1), one.led_count);
    try std.testing.expectEqual(@as(usize, 0), one.switch_count);
}
