//! Host tests for the time bar's speed field box (RA8EMU-808): the longest
//! text the field takes is painted whole, and its caret stays left of the
//! dropdown arrow.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const bar = gui_app.time_bar;
const speed_field = gui_app.speed_field;
const dark = &gui_app.colors.palettes.dark;
const Rect = draw_list.Rect;

const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = bar.height };

fn render(frame: *raster.Framebuffer, view: bar.View) !void {
    var list = draw_list.DrawList.init(std.testing.allocator, 480, bar.height);
    defer list.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    bar.draw(&paint, dark, area, view);
    raster.draw(frame, &list, font.atlas);
}

test "the field box leaves the whole longest text its room beside the arrow" {
    const layout = bar.Layout.of(area);
    const text_room = layout.field.w - bar.drop_w - 2 * bar.pad;
    try std.testing.expect(text_room >= @as(i32, @intCast(font.textWidth(speed_field.max_chars))));
    try std.testing.expectEqual(layout.field.x + layout.field.w - bar.drop_w, bar.dropBox(layout.field).x);
}

test "a long valid factor paints every character, and a full edit's caret stays off the arrow" {
    const factor = "999999.999x";
    try std.testing.expectEqual(@as(?u64, 999_999_999), speed_field.parse(factor));
    const layout = bar.Layout.of(area);
    var frame = try raster.Framebuffer.init(std.testing.allocator, 480, bar.height);
    defer frame.deinit(std.testing.allocator);
    try render(&frame, .{ .field = factor });

    const top = layout.field.y + draw_list.centre(layout.field.h, font.glyph_h);
    for (factor, 0..) |char, index| {
        const origin = font.cell(char);
        const left = layout.field.x + bar.pad + @as(i32, @intCast(index * font.cell_w));
        for (0..font.cell_h) |row| for (0..font.cell_w) |column| {
            const inked = font.atlas.coverage[(origin.y + row) * font.atlas.width + origin.x + column] != 0;
            const at = frame.at(@intCast(left + @as(i32, @intCast(column))), @intCast(top + @as(i32, @intCast(row))));
            if (inked) try std.testing.expect(std.meta.eql(at, dark.ink)) else try std.testing.expect(!std.meta.eql(at, dark.ink));
        };
    }

    var full: [speed_field.max_chars]u8 = undefined;
    @memset(&full, '9');
    try render(&frame, .{ .field = &full, .editing = true });
    const caret_x = layout.field.x + bar.pad + @as(i32, @intCast(font.textWidth(full.len)));
    const arrow = bar.dropBox(layout.field);
    try std.testing.expect(caret_x < arrow.x);
    try std.testing.expect(std.meta.eql(frame.at(@intCast(caret_x), @intCast(layout.field.y + 2)), dark.ink));
    var y = layout.field.y + 1;
    while (y < layout.field.y + layout.field.h - 1) : (y += 1) {
        var x = arrow.x;
        while (x < arrow.x + arrow.w - 1) : (x += 1) try std.testing.expect(!std.meta.eql(frame.at(@intCast(x), @intCast(y)), dark.ink));
    }
}
