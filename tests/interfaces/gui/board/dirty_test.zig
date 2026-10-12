//! Host tests for the board feed's dirty rect (RA8EMU-823): an lcd_dirty
//! rectangle updates only its sub-rect of the panel buffer, arriving
//! rectangles fold into the union since the last draw, and a draw hands the
//! union over so the next one sees nothing.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const proto = ra8.rpc.session.rpc;
const colors = gui_app.colors;
const board = gui_app.shell.board;
const link = gui_app.session_link;
const Rect = draw_list.Rect;
const Color = draw_list.Color;

/// Encode an lcd_dirty event into `buf`, which must outlive the observe
/// that reads the payload.
fn lcdEvent(buf: []u8, x: u16, y: u16, width: u16, height: u16, grays: []const u8) link.Arrival {
    const encoded = proto.encode(proto.DirtyRect, .{
        .core = .cpu0,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .virtual_ns = 0,
        .pixels = grays,
    }, buf) catch unreachable;
    return .{ .event = .{ .topic = @backingInt(proto.Topic.lcd_dirty), .payload = encoded } };
}

test "a rectangle updates only its sub-rect of the panel buffer" {
    var feed = board.Board.init(std.testing.allocator);
    defer feed.deinit();
    const grays = [_]u8{ 200, 150, 100, 50, 20, 10, 5, 180 };
    var buf: [256]u8 = undefined;
    try feed.observe(lcdEvent(&buf, 2, 1, 4, 2, &grays));
    try std.testing.expect(feed.hasFrame());
    try std.testing.expectEqual(@as(u32, 6), feed.width);
    try std.testing.expectEqual(@as(u32, 3), feed.height);
    try std.testing.expectEqual(Color.rgb(200, 200, 200), feed.pixels[1 * 6 + 2]);
    try std.testing.expectEqual(Color.rgb(180, 180, 180), feed.pixels[2 * 6 + 5]);
    try std.testing.expectEqual(colors.unseen, feed.pixels[2 * 6 + 1]);
    try std.testing.expectEqual(colors.unseen, feed.pixels[0]);
    try std.testing.expectEqual(colors.unseen, feed.pixels[1 * 6 + 1]);
}

test "arriving rectangles fold into the union since the last draw" {
    var feed = board.Board.init(std.testing.allocator);
    defer feed.deinit();
    var grays: [12]u8 = @splat(9);
    var buf: [256]u8 = undefined;
    try feed.observe(lcdEvent(&buf, 0, 0, 6, 2, &grays));
    try feed.observe(lcdEvent(&buf, 10, 5, 2, 2, grays[0..4]));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 12, .h = 7 }, feed.dirty.?);
}

test "a draw hands the union over and the next one sees nothing" {
    var feed = board.Board.init(std.testing.allocator);
    defer feed.deinit();
    const grays = [_]u8{ 1, 1, 1, 1 };
    var buf: [256]u8 = undefined;
    try feed.observe(lcdEvent(&buf, 0, 0, 2, 2, &grays));
    const view = feed.view(null);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 2, .h = 2 }, view.dirty);
    try std.testing.expect(feed.dirty == null);
    const again = feed.view(null);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, again.dirty);
}
