//! Covers src/interfaces/gui/ui/camera_device_row.zig: the webcam device row's slots,
//! drawing and hits.
const std = @import("std");
const ra8 = @import("ra8");
const row_mod = ra8.gui.camera_device_row;
const DrawList = ra8.gui.draw_list.DrawList;

const row = row_mod.Row{ .x = 10, .y = 40 };
const devices = [_]u32{ 0, 2, 10 };

test "the row sits under the panel's dialog row" {
    const layout = ra8.gui.camera_view.Layout{ .x = 5, .y = 7 };
    const under = row_mod.Row.under(layout);
    try std.testing.expectEqual(layout.x, under.x);
    try std.testing.expectEqual(layout.area().y + layout.area().h, under.y);
}

test "a click on a slot names its device; a miss names none" {
    for (devices, 0..) |device, index| {
        const at = row.slot(index);
        try std.testing.expectEqual(@as(?u32, device), row_mod.hit(row, &devices, at.x + 1, at.y + 1));
    }
    try std.testing.expectEqual(@as(?u32, null), row_mod.hit(row, &devices, 0, 0));
    try std.testing.expectEqual(@as(?u32, null), row_mod.hit(row, &.{}, row.slot(0).x + 1, row.slot(0).y + 1));
}

test "no devices draw nothing; the chosen one is ringed" {
    var list = DrawList.init(std.testing.allocator, 256, 128);
    defer list.deinit();
    try row_mod.draw(&list, row, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
    try row_mod.draw(&list, row, &devices, null);
    const plain = list.commands.items.len;
    // Background, three slots, and the glyphs of v0, v2 and v10.
    try std.testing.expectEqual(@as(usize, 1 + devices.len + 7), plain);
    list.commands.clearRetainingCapacity();
    try row_mod.draw(&list, row, &devices, 2);
    try std.testing.expectEqual(plain + 1, list.commands.items.len);
}
