//! Tests for src/interfaces/cli/board_view.zig.
const std = @import("std");
const ra8 = @import("ra8");
const view = ra8.board.report.frame_out.board_view;

test "the view adds the margin on every side and the LED strip below" {
    const got = view.size(4, 2);
    try std.testing.expectEqual(@as(u32, 4 + 2 * view.margin), got.width);
    try std.testing.expectEqual(@as(u32, 2 + 2 * view.margin + view.strip), got.height);
}

test "RGB565 widens to opaque ARGB with the high bits copied low" {
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), view.argbOf(0x001F));
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), view.argbOf(0x07E0));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), view.argbOf(0xF800));
    try std.testing.expectEqual(@as(u32, 0xFF000000), view.argbOf(0));
}

fn composed(canvas: []u32, leds: []const view.Led) void {
    const panel = [_]u32{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC, 0xFF010203, 0xFF040506 };
    view.compose(canvas, &panel, 3, 2, leds);
}

test "the panel pixels land unchanged inside the bezel" {
    const size = comptime view.size(3, 2);
    var canvas: [size.width * size.height]u32 = undefined;
    composed(&canvas, &.{});
    const m = view.margin;
    try std.testing.expectEqual(@as(u32, 0xFF112233), view.at(&canvas, size.width, m, m));
    try std.testing.expectEqual(@as(u32, 0xFF778899), view.at(&canvas, size.width, m + 2, m));
    try std.testing.expectEqual(@as(u32, 0xFF040506), view.at(&canvas, size.width, m + 2, m + 1));
    try std.testing.expectEqual(view.bezel, view.at(&canvas, size.width, m - 1, m - 1));
    try std.testing.expectEqual(view.bezel, view.at(&canvas, size.width, m + 3, m + 2));
    try std.testing.expectEqual(view.pcb, view.at(&canvas, size.width, 0, 0));
}

test "a driven LED shows its colour and an idle one stays dark" {
    const size = comptime view.size(64, 1);
    var canvas: [size.width * size.height]u32 = undefined;
    const panel = @as([64]u32, @splat(0xFF000000));
    view.compose(&canvas, &panel, 64, 1, &.{ .{ .rgb565 = 0x001F, .on = true }, .{ .rgb565 = 0xF800, .on = false } });
    const top = 1 + 2 * view.margin + (view.strip - view.led_side) / 2 - view.margin / 2;
    const first = view.margin + 1;
    const second = view.margin + view.led_side + view.led_gap + 1;
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), view.at(&canvas, size.width, first, top + 1));
    try std.testing.expectEqual(view.dark, view.at(&canvas, size.width, second, top + 1));
    try std.testing.expectEqual(view.pcb, view.at(&canvas, size.width, second + view.led_side, top + 1));
}

test "an LED that would fall off the edge is left out" {
    const size = comptime view.size(3, 2);
    var canvas: [size.width * size.height]u32 = undefined;
    const lit = view.Led{ .rgb565 = 0x07E0, .on = true };
    composed(&canvas, &.{ lit, lit, lit, lit });
    try std.testing.expectEqual(view.pcb, view.at(&canvas, size.width, size.width - 1, size.height - 1));
}
