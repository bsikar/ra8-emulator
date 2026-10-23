//! Host tests for the history strip (slice 19, gui/history_strip.zig): the
//! geometry's clamps, what an empty track paints, the band and hatch across
//! the recorded boundary, the cursor's column, and that a click's fraction
//! maps back to the ends.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const strip = gui_app.history_strip;
const history_track = gui_app.history_track;

const Frame = draw_list.Rect;

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,
    theme: *const gui_app.colors.Theme = dark,
    width: u32,

    fn init(width: u32) !Scene {
        const h: u32 = @intCast(strip.height);
        return .{
            .list = draw_list.DrawList.init(std.testing.allocator, width, h),
            .frame = try raster.Framebuffer.init(std.testing.allocator, width, h),
            .width = width,
        };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, view: strip.View) !void {
        var target = ra8.render.widget_paint.Target{ .list = &self.list };
        const paint = target.paint();
        strip.draw(&paint, self.theme, .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = strip.height }, view);
        raster.draw(&self.frame, &self.list, font.atlas);
    }
};

test "history strip: geometry clamps to the body and answers the ends" {
    const at = Frame{ .x = 0, .y = 0, .w = 100, .h = strip.height };
    const b = strip.body(at);
    try std.testing.expectEqual(@as(i32, 4), b.x);
    try std.testing.expectEqual(@as(i32, 92), b.w);
    try std.testing.expectEqual(@as(i32, 4), strip.fractionToX(0, at));
    try std.testing.expectEqual(@as(i32, 96), strip.fractionToX(1, at));
    try std.testing.expectEqual(@as(i32, 50), strip.fractionToX(0.5, at));
    try std.testing.expectEqual(@as(f64, 0), strip.xToFraction(at, 4).?);
    try std.testing.expectEqual(@as(f64, 1), strip.xToFraction(at, 96).?);
    try std.testing.expectEqual(@as(f64, 0.5), strip.xToFraction(at, 50).?);
    try std.testing.expectEqual(@as(?f64, null), strip.xToFraction(at, 3));
    try std.testing.expectEqual(@as(?f64, null), strip.xToFraction(at, 97));
}

test "history strip: an empty track paints only the well" {
    var scene = try Scene.init(100);
    defer scene.deinit();
    try scene.render(.{});
    var y: u32 = 0;
    while (y < scene.frame.height) : (y += 1) {
        var x: u32 = 0;
        while (x < scene.width) : (x += 1) {
            try std.testing.expectEqual(dark.well, scene.frame.at(x, y));
        }
    }
}

test "history strip: the band fills the recorded part and the tail hatches" {
    var scene = try Scene.init(100);
    defer scene.deinit();
    const ten_s: u64 = 10 * std.time.ns_per_s;
    try scene.render(.{ .track = .{ .end_ns = ten_s, .current_ns = ten_s } });
    // Half the span is recorded: band through the middle of the left half.
    try std.testing.expectEqual(dark.band, scene.frame.at(10, 8));
    // The unrun tail: a hatch column at 54, a gap column at 52 (well).
    try std.testing.expectEqual(dark.muted, scene.frame.at(54, 8));
    try std.testing.expectEqual(dark.well, scene.frame.at(52, 8));
}

test "history strip: the cursor stands on the run's virtual time" {
    var scene = try Scene.init(100);
    defer scene.deinit();
    const ten_s: u64 = 10 * std.time.ns_per_s;
    const five_s: u64 = 5 * std.time.ns_per_s;
    try scene.render(.{ .track = .{ .end_ns = ten_s, .current_ns = five_s } });
    // A quarter across the span: x = 4 + round(0.25 * 92) = 27.
    try std.testing.expectEqual(dark.pc_cyan, scene.frame.at(27, 8));
    try std.testing.expectEqual(dark.band, scene.frame.at(10, 8));
}

test "history strip: checkpoint marks tick the recorded part" {
    var scene = try Scene.init(100);
    defer scene.deinit();
    const ten_s: u64 = 10 * std.time.ns_per_s;
    const marks = [_]history_track.Mark{.{ .ns = ten_s / 2, .index = 0 }};
    try scene.render(.{ .track = .{ .end_ns = ten_s, .current_ns = ten_s }, .marks = &marks });
    // Half the recorded end across the whole span: x = 4 + round(0.25 * 92).
    try std.testing.expectEqual(dark.accent, scene.frame.at(27, 8));
}
