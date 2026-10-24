//! Tests for src/interfaces/gui/ui/branch_list.zig (Slice 20.4 minimal branch list).
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const branch_list = gui_app.branch_list;
const draw_list = ra8.render.draw_list;

const Rect = draw_list.Rect;

test "branch list hit testing for switch and delete confirmation" {
    const area = Rect{ .x = 50, .y = 50, .w = 400, .h = 300 };

    const items = [_]branch_list.Item{
        .{ .id = 0, .parent = 0, .fork_r = 0, .end_r = 100, .is_live = true },
        .{ .id = 1, .parent = 0, .fork_r = 50, .end_r = 80, .is_live = false },
    };

    // Live branch 0: clicking switch area does nothing
    const hit_live = branch_list.hit(area, &items, null, area.x + area.w - 120, area.y + branch_list.row_h + 5);
    try std.testing.expectEqual(branch_list.Action.none, hit_live);

    // Non-live branch 1: clicking switch button
    const hit_sw = branch_list.hit(area, &items, null, area.x + area.w - 120, area.y + 2 * branch_list.row_h + 5);
    try std.testing.expectEqual(branch_list.Action{ .switch_branch = 1 }, hit_sw);

    // Non-live branch 1: clicking del button when not confirming
    const hit_del = branch_list.hit(area, &items, null, area.x + area.w - 30, area.y + 2 * branch_list.row_h + 5);
    try std.testing.expectEqual(branch_list.Action{ .request_delete = 1 }, hit_del);

    // When confirming branch 1: clicking confirm
    const hit_confirm = branch_list.hit(area, &items, 1, area.x + area.w - 60, area.y + 2 * branch_list.row_h + 5);
    try std.testing.expectEqual(branch_list.Action{ .confirm_delete = 1 }, hit_confirm);

    // When confirming branch 1: clicking cancel 'X'
    const hit_cancel = branch_list.hit(area, &items, 1, area.x + area.w - 15, area.y + 2 * branch_list.row_h + 5);
    try std.testing.expectEqual(branch_list.Action.cancel_delete, hit_cancel);
}
