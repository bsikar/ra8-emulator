//! Host tests for the timeline pane's paint (RA8EMU-836): a too-small pane
//! draws nothing, the ruler's step adapts to the zoom, lanes order ISR rows
//! above thread rows with idle last, and the base and zoomed views render
//! differently. Goldens get pinned after their frames are viewed.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const dark = &gui_app.colors.palettes.dark;
const pane = gui_app.timeline_pane;
const timeline_model = gui_app.timeline_model;

const allocator = std.testing.allocator;
const Rect = draw_list.Rect;

/// The synthetic run: core 0 runs thread A, a nested ISR, thread B, then
/// idles; core 1 runs thread C and idles. Two cores, three threads, ISRs.
const events = [_]timeline_model.rtos_trace.Event{
    .{ .when = 100, .core = 0, .kind = .switch_to, .thread = 0xA },
    .{ .when = 200, .core = 1, .kind = .switch_to, .thread = 0xC },
    .{ .when = 300, .core = 0, .kind = .enter, .exception = 15 },
    .{ .when = 350, .core = 0, .kind = .enter, .exception = 16 },
    .{ .when = 450, .core = 0, .kind = .leave, .exception = 16 },
    .{ .when = 500, .core = 0, .kind = .leave, .exception = 15 },
    .{ .when = 700, .core = 0, .kind = .switch_to, .thread = 0xB },
    .{ .when = 800, .core = 1, .kind = .idle },
    .{ .when = 900, .core = 0, .kind = .idle },
};

fn recorded() !timeline_model.Model {
    var model = timeline_model.Model.init(allocator);
    errdefer model.deinit();
    for (events) |one| try model.take(one);
    try model.finish(1000);
    return model;
}

/// A frame nothing drew, for the draws-nothing comparison.
fn blankDigest(w: i32, h: i32) !u64 {
    var frame = try raster.Framebuffer.init(allocator, @intCast(w), @intCast(h));
    defer frame.deinit(allocator);
    var list = draw_list.DrawList.init(allocator, @intCast(w), @intCast(h));
    defer list.deinit();
    raster.draw(&frame, &list, ra8.render.font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

fn digest(view: timeline_model.View, w: i32, h: i32) !u64 {
    const area = Rect{ .x = 0, .y = 0, .w = w, .h = h };
    var model = try recorded();
    defer model.deinit();
    var list = draw_list.DrawList.init(allocator, @intCast(w), @intCast(h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(allocator, @intCast(w), @intCast(h));
    defer frame.deinit(allocator);
    try pane.draw(&list, dark, area, &model, view);
    raster.draw(&frame, &list, ra8.render.font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "a pane too small to draw draws nothing" {
    const tiny = try digest(timeline_model.View{ .width_px = 1 }, pane.col_w + 15, 200);
    try std.testing.expectEqual(try blankDigest(pane.col_w + 15, 200), tiny);
    const short = try digest(timeline_model.View{ .width_px = 1 }, 240, pane.ruler_h + pane.header_h + pane.row_h - 1);
    try std.testing.expectEqual(try blankDigest(240, pane.ruler_h + pane.header_h + pane.row_h - 1), short);
}

test "the ruler's step adapts to the zoom" {
    try std.testing.expectEqual(@as(u64, 1), pane.rulerStep(8));
    try std.testing.expectEqual(@as(u64, 2), pane.rulerStep(9));
    try std.testing.expectEqual(@as(u64, 5), pane.rulerStep(25));
    try std.testing.expectEqual(@as(u64, 10), pane.rulerStep(80));
    try std.testing.expectEqual(@as(u64, 100), pane.rulerStep(800));
    try std.testing.expectEqual(@as(u64, 1000), pane.rulerStep(8000));
}

test "lanes order isr rows above thread rows with idle last" {
    var model = try recorded();
    defer model.deinit();
    var buf: [64]usize = undefined;
    const order = pane.laneOrder(&model, 0, &buf);
    try std.testing.expectEqual(@as(usize, 5), order.len);
    const kinds = [_]timeline_model.rtos_load.Kind{ .exception, .exception, .thread, .thread, .idle };
    const ids = [_]u32{ 15, 16, 0xA, 0xB, 0 };
    for (order, kinds, ids) |index, kind, id| {
        const lane = model.laneAt(index);
        try std.testing.expectEqual(kind, lane.kind);
        try std.testing.expectEqual(id, lane.id);
    }
}

test "the base and zoomed views render differently" {
    const window: timeline_model.rtos_load.Window = blk: {
        var m = try recorded();
        defer m.deinit();
        break :blk m.recorded().?;
    };
    const base = timeline_model.View{ .start_ns = 100, .span_ns = 900, .width_px = 240 - pane.col_w };
    const close = base.zoom(500, 1, 1000, window);
    try std.testing.expect(!std.meta.eql(base, close));
    try std.testing.expect(try digest(base, 240, 200) != try digest(close, 240, 200));
}

const BASE_DIGEST: u64 = 11615213356698412093;
const ZOOM_DIGEST: u64 = 14490861355837945656;

test "the base view matches its pinned golden" {
    const base = timeline_model.View{ .start_ns = 100, .span_ns = 900, .width_px = 480 - pane.col_w };
    try std.testing.expectEqual(BASE_DIGEST, try digest(base, 480, 320));
}

test "the 1000x zoom view matches its pinned golden" {
    const window: timeline_model.rtos_load.Window = blk: {
        var m = try recorded();
        defer m.deinit();
        break :blk m.recorded().?;
    };
    const base = timeline_model.View{ .start_ns = 100, .span_ns = 900, .width_px = 480 - pane.col_w };
    const zoomed = base.zoom(500, 1, 1000, window);
    try std.testing.expectEqual(ZOOM_DIGEST, try digest(zoomed, 480, 320));
}
