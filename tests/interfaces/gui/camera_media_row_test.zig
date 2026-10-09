//! Covers src/interfaces/gui/camera_media_row.zig: the picture and clip row's place
//! under the panel, its slots and the chosen file's ring.
const std = @import("std");
const ra8 = @import("ra8");
const row = ra8.gui.camera_media_row;
const view = ra8.gui.camera_view;
const DrawList = ra8.gui.draw_list.DrawList;

const names = [_][]const u8{ "a.png", "b.png" };

test "the row sits under the device row only when that row shows" {
    const layout = view.Layout{ .x = 10, .y = 20 };
    const panel = layout.area();
    try std.testing.expectEqual(panel.y + panel.h, row.rowFor(layout, 0).y);
    try std.testing.expectEqual(panel.y + panel.h + view.button + view.gap, row.rowFor(layout, 2).y);
    try std.testing.expectEqual(panel.x, row.rowFor(layout, 2).x);
}

test "a click on a slot names its file; a miss names none" {
    const at = row.rowFor(.{ .x = 0, .y = 0 }, 0);
    const second = at.slot(1);
    try std.testing.expectEqualStrings("b.png", row.hit(at, &names, second.x + 1, second.y + 1).?);
    try std.testing.expect(row.hit(at, &names, second.x + second.w + view.gap + 50, second.y + 1) == null);
    try std.testing.expect(row.hit(at, &.{}, second.x + 1, second.y + 1) == null);
}

test "no files draws nothing; the chosen file is ringed" {
    var list = DrawList.init(std.testing.allocator, 400, 200);
    defer list.deinit();
    const at = row.rowFor(.{ .x = 0, .y = 0 }, 0);
    try row.draw(&list, at, &.{}, "", view.camera_off);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
    try row.draw(&list, at, &names, "", view.camera_off);
    // Background, two slots, and the stems "a" and "b".
    try std.testing.expectEqual(@as(usize, 5), list.commands.items.len);
    list.commands.clearRetainingCapacity();
    try row.draw(&list, at, &names, "b.png", view.camera_off);
    try std.testing.expectEqual(@as(usize, 6), list.commands.items.len);
}
