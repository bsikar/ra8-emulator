//! Host tests for GUI filmstrip (Slice 23.5).
//! Tests thumbnail layout, hover preview resolution, nearest checkpoint search,
//! click seeking, and paint integration.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const filmstrip = gui_app.filmstrip;
const strip = gui_app.history_strip;

const Rect = draw_list.Rect;

test "filmstrip: add and capacity" {
    var fs: filmstrip.Filmstrip = .{};
    fs.clear();
    try std.testing.expectEqual(@as(usize, 0), fs.items().len);

    for (0..filmstrip.max_thumbnails) |i| {
        const ok = fs.add(.{
            .checkpoint_id = @intCast(i + 1),
            .virtual_ns = @as(u64, @intCast(i)) * 1000,
        });
        try std.testing.expect(ok);
    }
    try std.testing.expectEqual(filmstrip.max_thumbnails, fs.items().len);

    // Overflow rejected
    const overflow = fs.add(.{ .checkpoint_id = 999, .virtual_ns = 50000 });
    try std.testing.expect(!overflow);

    fs.clear();
    try std.testing.expectEqual(@as(usize, 0), fs.items().len);
}

test "filmstrip: layout positions along strip" {
    var fs: filmstrip.Filmstrip = .{};
    fs.clear();
    _ = fs.add(.{ .checkpoint_id = 1, .virtual_ns = 0 });
    _ = fs.add(.{ .checkpoint_id = 2, .virtual_ns = 5000 });
    _ = fs.add(.{ .checkpoint_id = 3, .virtual_ns = 10000 });

    const at = Rect{ .x = 10, .y = 100, .w = 108, .h = 20 };
    fs.updateLayout(at, 10000);

    const items = fs.items();
    try std.testing.expectEqual(@as(usize, 3), items.len);

    // First at fraction 0: center_x = 10 + 4 = 14
    try std.testing.expectEqual(@as(i32, 14 - @divTrunc(filmstrip.thumb_width, 2)), items[0].rect.x);
    // Third at fraction 1.0: center_x = 14 + 100 = 114
    try std.testing.expectEqual(@as(i32, 114 - @divTrunc(filmstrip.thumb_width, 2)), items[2].rect.x);
    // Middle at fraction 0.5: center_x = 14 + 50 = 64
    try std.testing.expectEqual(@as(i32, 64 - @divTrunc(filmstrip.thumb_width, 2)), items[1].rect.x);
}

test "filmstrip: nearest index resolution" {
    var fs: filmstrip.Filmstrip = .{};
    fs.clear();
    _ = fs.add(.{ .checkpoint_id = 1, .virtual_ns = 1000 });
    _ = fs.add(.{ .checkpoint_id = 2, .virtual_ns = 5000 });
    _ = fs.add(.{ .checkpoint_id = 3, .virtual_ns = 9000 });

    // 0.1 of 10000 is 1000 -> index 0
    try std.testing.expectEqual(@as(?usize, 0), fs.nearestIndex(0.1, 10000));
    // 0.45 of 10000 is 4500 -> index 1
    try std.testing.expectEqual(@as(?usize, 1), fs.nearestIndex(0.45, 10000));
    // 0.95 of 10000 is 9500 -> index 2
    try std.testing.expectEqual(@as(?usize, 2), fs.nearestIndex(0.95, 10000));
}

test "filmstrip: hover preview box calculation" {
    var fs: filmstrip.Filmstrip = .{};
    fs.clear();
    _ = fs.add(.{ .checkpoint_id = 42, .virtual_ns = 5000 });

    const at = Rect{ .x = 0, .y = 100, .w = 200, .h = 20 };
    fs.setHoverFraction(0.5);

    const prev = fs.hoverPreview(at, 10000);
    try std.testing.expect(prev != null);
    try std.testing.expectEqual(@as(u32, 42), prev.?.checkpoint_id);
    try std.testing.expectEqual(@as(u64, 5000), prev.?.virtual_ns);
    try std.testing.expectEqual(filmstrip.popover_width, prev.?.rect.w);
    try std.testing.expectEqual(filmstrip.popover_height, prev.?.rect.h);
}

test "filmstrip: seekAt resolves virtual time" {
    var fs: filmstrip.Filmstrip = .{};
    fs.clear();
    _ = fs.add(.{ .checkpoint_id = 1, .virtual_ns = 2500 });
    _ = fs.add(.{ .checkpoint_id = 2, .virtual_ns = 7500 });

    const at = Rect{ .x = 0, .y = 100, .w = 108, .h = 20 };
    fs.updateLayout(at, 10000);

    // Click near item 0
    const t0 = fs.seekAt(at, fs.items()[0].rect.x + 2, 105, 10000);
    try std.testing.expectEqual(@as(?u64, 2500), t0);

    // Click near item 1
    const t1 = fs.seekAt(at, fs.items()[1].rect.x + 2, 105, 10000);
    try std.testing.expectEqual(@as(?u64, 7500), t1);
}

test "filmstrip: renders in history strip without panic" {
    var fs: filmstrip.Filmstrip = .{};
    fs.clear();
    _ = fs.add(.{ .checkpoint_id = 1, .virtual_ns = 2000, .has_frame = true });
    _ = fs.add(.{ .checkpoint_id = 2, .virtual_ns = 8000, .has_frame = false });

    const width: u32 = 200;
    const height: u32 = @intCast(strip.height);
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, width, height);
    defer frame.deinit(std.testing.allocator);

    const at = Rect{ .x = 0, .y = 0, .w = @intCast(width), .h = strip.height };
    fs.updateLayout(at, 10000);
    fs.setHoverFraction(0.2);

    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    strip.draw(&paint, dark, at, .{
        .track = .{ .end_ns = 10000, .current_ns = 5000 },
        .filmstrip = &fs,
    });
    raster.draw(&frame, &list, font.atlas);
}
