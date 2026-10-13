//! Covers src/interfaces/gui/camera/rows.zig: the leaf's listing rows'
//! layout (the media row under the device row), a click finding the right
//! slot, and the rows painting with the chosen entry ringed (RA8EMU-1123).
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const draw_list = ra8.render.draw_list;
const gui_app = @import("gui_app");
const rows = gui_app.camera.rows;

test "the rows stack under the preview: media under devices, neither alone" {
    const body = draw_list.Rect{ .x = 0, .y = 0, .w = 200, .h = 200 };
    var stack = rows.stackFor(body, 2, 3).?;
    try std.testing.expectEqual(@as(i32, 200 - 4 - 2 * (24 + 4)), stack.top);
    try std.testing.expectEqual(@as(i32, 2 * (24 + 4)), stack.height());
    try std.testing.expectEqual(@as(i32, 200 - 4 - 2 * (24 + 4)), stack.device().?.y);
    try std.testing.expectEqual(@as(i32, 200 - 4 - 2 * (24 + 4) + 28), stack.media().?.y);
    stack = rows.stackFor(body, 0, 3).?;
    try std.testing.expect(stack.device() == null);
    try std.testing.expectEqual(@as(i32, 200 - 4 - (24 + 4)), stack.media().?.y);
    try std.testing.expect(rows.stackFor(body, 0, 0) == null);
}

test "a click finds its slot; one between slots finds nothing" {
    const devices = [_]u32{ 0, 2 };
    const names = [_][]const u8{ "a.png", "b.png" };
    var stack = rows.Stack{ .x = 0, .top = 100, .device_count = 2, .media_count = 2 };
    const d = stack.device().?;
    const at = d.slot(1);
    try std.testing.expectEqual(@as(u32, 2), rows.hitDevices(d, &devices, at.x + @divTrunc(at.w, 2), at.y + @divTrunc(at.h, 2)).?);
    const m = stack.media().?;
    const name_at = m.slot(0);
    try std.testing.expectEqualStrings("a.png", rows.hitMedia(m, &names, name_at.x + @divTrunc(name_at.w, 2), name_at.y + @divTrunc(name_at.h, 2)).?);
    const miss = d.area(2);
    try std.testing.expect(rows.hitDevices(d, &devices, miss.x + @divTrunc(miss.w, 2), miss.y + @divTrunc(miss.h, 2)) == null);
}

test "the rows paint their slots and the chosen one's ring" {
    var list = draw_list.DrawList.init(std.testing.allocator, 256, 128);
    defer list.deinit();
    const devices = [_]u32{0};
    const names = [_][]const u8{"clip.y4m"};
    var stack = rows.Stack{ .x = 0, .top = 0, .device_count = 1, .media_count = 1 };
    try rows.drawDevices(dark, &list, stack.device().?, &devices, 0);
    try rows.drawMedia(dark, &list, stack.media().?, &names, "clip.y4m", dark.hue.purple);
}
