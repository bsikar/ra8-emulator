//! Host tests for GUI state diff viewer pane (Slice 23.5).
//! Tests DiffView data model, section formatting, scroll clamping,
//! and paint rendering.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const diff_pane = gui_app.diff_pane;

const Rect = draw_list.Rect;

test "diff pane: data model and capacity" {
    var view: diff_pane.DiffView = .{};
    view.clear();
    try std.testing.expect(!view.has_data);
    try std.testing.expectEqual(@as(usize, 0), view.regs_len);
    try std.testing.expectEqual(@as(usize, 0), view.pages_len);
    try std.testing.expectEqual(@as(usize, 0), view.periphs_len);

    const r_ok = view.addReg(0, "R0", 0x1000, 0x2000);
    try std.testing.expect(r_ok);
    try std.testing.expect(view.has_data);
    try std.testing.expectEqual(@as(usize, 1), view.regs_len);

    const p_ok = view.addPage(0x2000_0000, 16);
    try std.testing.expect(p_ok);
    try std.testing.expectEqual(@as(usize, 1), view.pages_len);

    const pr_ok = view.addPeriph("GPT0", "GTCNT", 0x10, 0x20);
    try std.testing.expect(pr_ok);
    try std.testing.expectEqual(@as(usize, 1), view.periphs_len);

    // Total rows: 1 header + (1 sec + 1 reg) + (1 sec + 1 page) + (1 sec + 1 periph) = 7
    try std.testing.expectEqual(@as(usize, 7), view.totalRows());

    view.clear();
    try std.testing.expect(!view.has_data);
    try std.testing.expectEqual(@as(usize, 0), view.regs_len);
}

test "diff pane: scroll bounds clamping" {
    var view: diff_pane.DiffView = .{};
    view.clear();
    for (0..10) |i| {
        _ = view.addReg(0, "R0", @intCast(i), @intCast(i + 1));
    }
    const area = Rect{ .x = 0, .y = 0, .w = 300, .h = 100 };

    // Scroll down
    view.scroll(50, area);
    try std.testing.expect(view.scroll_offset > 0);

    // Scroll way past end: clamped to max_scroll
    view.scroll(10000, area);
    const max_scroll = @as(i32, @intCast(view.totalRows() * diff_pane.row_h)) - area.h;
    try std.testing.expectEqual(max_scroll, view.scroll_offset);

    // Scroll up past 0: clamped to 0
    view.scroll(-20000, area);
    try std.testing.expectEqual(@as(i32, 0), view.scroll_offset);
}

test "diff pane: renders empty state without panic" {
    var view: diff_pane.DiffView = .{};
    view.clear();

    const width: u32 = 300;
    const height: u32 = 200;
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, width, height);
    defer frame.deinit(std.testing.allocator);

    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    const area = Rect{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) };

    diff_pane.draw(&paint, dark, area, &view);
    raster.draw(&frame, &list, font.atlas);
}

test "diff pane: renders populated diff without panic" {
    var view: diff_pane.DiffView = .{};
    view.clear();
    view.pos_a = .{ .branch = 0, .r = 100, .phase = .cpu0, .o = 0, .gap = .retired };
    view.pos_b = .{ .branch = 1, .r = 150, .phase = .cpu0, .o = 0, .gap = .retired };
    _ = view.addReg(0, "R0", 0x1000, 0x2000);
    _ = view.addReg(1, "SP", 0x2000_1000, 0x2000_0fe0);
    _ = view.addPage(0x2000_0000, 64);
    _ = view.addPeriph("GPT0", "GTCNT", 0, 100);

    const width: u32 = 350;
    const height: u32 = 300;
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, width, height);
    defer frame.deinit(std.testing.allocator);

    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    const area = Rect{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) };

    diff_pane.draw(&paint, dark, area, &view);
    raster.draw(&frame, &list, font.atlas);
}
