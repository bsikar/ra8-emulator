//! Host tests for the speed dropdown popover (RA8EMU-807).
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const Theme = @import("gui_app").colors.Theme;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const speed_field = gui_app.speed_field;
const bar = gui_app.time_bar;
const Rect = draw_list.Rect;

fn middle(area: Rect) [2]i32 {
    return .{ area.x + @divTrunc(area.w, 2), area.y + @divTrunc(area.h, 2) };
}

test "the speed dropdown popover hit test and open rendering" {
    const area: Rect = .{ .x = 0, .y = 150, .w = 480, .h = bar.height };
    const layout = bar.Layout.of(area);
    const pop = bar.popover(layout.field);
    try std.testing.expect(pop.y < layout.field.y);
    try std.testing.expectEqual(layout.field.w, pop.w);

    const row0 = middle(bar.popoverRow(layout.field, 0));
    try std.testing.expectEqual(@as(?usize, null), bar.hitDropdown(layout.field, false, row0[0], row0[1]));

    for (0..speed_field.presets.len) |i| {
        const at = middle(bar.popoverRow(layout.field, i));
        try std.testing.expectEqual(@as(?usize, i), bar.hitDropdown(layout.field, true, at[0], at[1]));
    }

    try std.testing.expectEqual(@as(?usize, null), bar.hitDropdown(layout.field, true, pop.x - 5, pop.y));

    for ([_]*const Theme{ dark, light }) |theme| {
        var list = draw_list.DrawList.init(std.testing.allocator, 480, 200);
        defer list.deinit();
        var frame = try raster.Framebuffer.init(std.testing.allocator, 480, 200);
        defer frame.deinit(std.testing.allocator);
        var target = ra8.render.widget_paint.Target{ .list = &list };
        const paint = target.paint();
        const view: bar.View = .{ .field = "1x", .applied = 1000, .open = true };
        bar.draw(&paint, theme, area, view);
        raster.draw(&frame, &list, font.atlas);
        const hash = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
        try std.testing.expect(hash != 0);
    }
}
