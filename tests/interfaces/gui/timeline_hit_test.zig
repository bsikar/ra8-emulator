//! Host tests for the timeline pane's slice click (RA8EMU-838): a click
//! over a slice returns the slice painted there with its start time, and
//! the name column, a core header, the ruler and empty lane space return
//! null. The shared cursor moves to a slice's start and clears back.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const pane = gui_app.timeline_pane;
const cursor_mod = gui_app.time_cursor;
const timeline_model = gui_app.timeline_model;

const allocator = std.testing.allocator;
const Rect = ra8.render.draw_list.Rect;

const events = [_]timeline_model.rtos_trace.Event{
    .{ .when = 100, .core = 0, .kind = .switch_to, .thread = 0xA },
    .{ .when = 700, .core = 0, .kind = .switch_to, .thread = 0xB },
    .{ .when = 900, .core = 0, .kind = .idle },
};

fn recorded() !timeline_model.Model {
    var model = timeline_model.Model.init(allocator);
    errdefer model.deinit();
    for (events) |one| try model.take(one);
    try model.finish(1000);
    return model;
}

fn fixture() struct { area: Rect, view: timeline_model.View } {
    const area = Rect{ .x = 0, .y = 0, .w = 400, .h = pane.ruler_h + pane.header_h + 4 * pane.row_h };
    const view = timeline_model.View{ .start_ns = 0, .span_ns = 1000, .width_px = 400 };
    return .{ .area = area, .view = view };
}

test "click over a slice returns its start time" {
    var model = try recorded();
    defer model.deinit();
    const fx = fixture();
    const rows_x = pane.col_w;
    const hit = pane.hitAt(fx.area, &model, fx.view, rows_x + 192, pane.header_h + 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 100), hit.start_ns);
}

test "clicks off the slices return null" {
    var model = try recorded();
    defer model.deinit();
    const fx = fixture();
    const rows_x = pane.col_w;
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), pane.hitAt(fx.area, &model, fx.view, rows_x + 20, pane.header_h + 2));
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), pane.hitAt(fx.area, &model, fx.view, rows_x + 100, 50));
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), pane.hitAt(fx.area, &model, fx.view, 50, pane.header_h + 2));
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), pane.hitAt(fx.area, &model, fx.view, rows_x + 100, fx.area.h - 2));
}

test "a lane past its drawn rows returns null" {
    var model = try recorded();
    defer model.deinit();
    const fx = fixture();
    const y = pane.header_h + 3 * pane.row_h + 2;
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), pane.hitAt(fx.area, &model, fx.view, pane.col_w + 100, y));
}

test "the cursor moves to a slice and clears back" {
    var cursor = cursor_mod.Cursor{};
    try std.testing.expect(cursor.isLive());
    cursor.moveTo(300);
    try std.testing.expectEqual(@as(?u64, 300), cursor.at_ns);
    try std.testing.expect(!cursor.isLive());
    cursor.clear();
    try std.testing.expect(cursor.isLive());
}
