//! Host tests for the LCD pane's scrubber strip (RA8EMU-825): the strip
//! sits under the panel and a too-short area gets none, a frame set shows
//! only what fits, a selected frame's cell lights and the label names its
//! virtual stamp, the live state labels itself, and both states match
//! pinned golden frames through raster.draw.

const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const dark = &gui_app.colors.palettes.dark;
const scrubber = gui_app.lcd_scrubber;
const Rect = draw_list.Rect;

const area: Rect = .{ .x = 0, .y = 0, .w = 240, .h = scrubber.strip_h + 10 };

const SELECTED_DIGEST: u64 = 15053858282827128293;
const LIVE_DIGEST: u64 = 17136865642743636592;

fn render(view: scrubber.View, path: [:0]const u8) !u64 {
    var list = draw_list.DrawList.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer frame.deinit(std.testing.allocator);
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    scrubber.draw(&paint, dark, area, view);
    raster.draw(&frame, &list, font.atlas);
    {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try out.print(std.testing.allocator, "P6\n{d} {d}\n255\n", .{ frame.width, frame.height });
        for (frame.pixels) |p| try out.appendSlice(std.testing.allocator, &.{ p.r, p.g, p.b });
        const file = std.c.fopen(path, "wb") orelse return error.Open;
        _ = std.c.fwrite(out.items.ptr, 1, out.items.len, file);
        _ = std.c.fclose(file);
    }
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "the strip sits under the panel and a too-short area gets no strip" {
    try std.testing.expectEqual(area.h - scrubber.strip_h, scrubber.strip(area).y);
    try std.testing.expectEqual(scrubber.strip_h, scrubber.strip(area).h);
    const short = Rect{ .x = 0, .y = 0, .w = 240, .h = scrubber.strip_h - 1 };
    try std.testing.expectEqual(@as(i32, 0), scrubber.strip(short).h);
}

test "a frame set shows only what fits, newest frames at the right" {
    const wide = Rect{ .x = 0, .y = 0, .w = 2 * scrubber.pad + scrubber.cell_w, .h = 34 };
    try std.testing.expectEqual(@as(usize, 1), scrubber.fits(wide));
    try std.testing.expectEqual(@as(usize, 0), scrubber.fits(.{ .x = 0, .y = 0, .w = scrubber.pad * 2 - 1, .h = 34 }));
    const shown = scrubber.fits(area);
    try std.testing.expect(shown < 40);
    try std.testing.expectEqual(@as(usize, shown), scrubber.fits(area));
}

test "the label names the selected stamp or live" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("live", scrubber.label(.{ .count = 3 }, &buf));
    const shown = scrubber.label(.{ .count = 12, .selected = 7, .stamp = 987654321 }, &buf);
    try std.testing.expectEqualStrings("t=987654321ns", shown);
    try std.testing.expectEqualStrings("live", scrubber.label(.{ .count = 3, .selected = 3 }, &buf));
}

test "the selected-state strip matches its pinned golden frame" {
    const got = try render(.{ .count = 12, .selected = 7, .stamp = 987654321 }, "/tmp/scrub_sel.ppm");
    try std.testing.expectEqual(SELECTED_DIGEST, got);
}

test "the live strip matches its pinned golden frame" {
    const got = try render(.{ .count = 12 }, "/tmp/scrub_live.ppm");
    try std.testing.expectEqual(LIVE_DIGEST, got);
}

test "a different stamp changes the frame and nothing paints past the area" {
    const a = try render(.{ .count = 12, .selected = 7, .stamp = 1 }, "/tmp/scrub_s1.ppm");
    const b = try render(.{ .count = 12, .selected = 7, .stamp = 2 }, "/tmp/scrub_s2.ppm");
    try std.testing.expect(a != b);
}
