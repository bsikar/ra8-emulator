//! Host tests for GUI branch tree visualization (Slice 23.5).
//! Tests tree layout calculation, bifurcation points, active line tracing,
//! hit testing for branch switching, and paint rendering.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const branch_tree = gui_app.branch_tree;

const Rect = draw_list.Rect;
const Item = branch_tree.Item;

test "branch tree: layout computes lanes and rows" {
    const items = [_]Item{
        .{ .id = 0, .parent = 0, .fork_r = 0, .end_r = 100, .is_live = false },
        .{ .id = 1, .parent = 0, .fork_r = 50, .end_r = 80, .is_live = true },
    };

    const area = Rect{ .x = 10, .y = 20, .w = 400, .h = 300 };
    const tree = branch_tree.TreeLayout.compute(area, &items);

    try std.testing.expectEqual(@as(usize, 2), tree.count);

    // Root node
    try std.testing.expectEqual(@as(i32, 0), tree.nodes[0].lane);
    try std.testing.expectEqual(@as(i32, 0), tree.nodes[0].row);
    try std.testing.expectEqual(@as(i32, 10 + branch_tree.pad), tree.nodes[0].rect.x);

    // Child node
    try std.testing.expectEqual(@as(i32, 1), tree.nodes[1].lane);
    try std.testing.expectEqual(@as(i32, 1), tree.nodes[1].row);
    try std.testing.expectEqual(@as(i32, 10 + branch_tree.pad + branch_tree.lane_width), tree.nodes[1].rect.x);
}

test "branch tree: active line path tracing" {
    // 0 -> 1 -> 2 (live)
    // 0 -> 3 (not live)
    const items = [_]Item{
        .{ .id = 0, .parent = 0, .fork_r = 0, .end_r = 100, .is_live = false },
        .{ .id = 1, .parent = 0, .fork_r = 30, .end_r = 70, .is_live = false },
        .{ .id = 2, .parent = 1, .fork_r = 50, .end_r = 90, .is_live = true },
        .{ .id = 3, .parent = 0, .fork_r = 40, .end_r = 60, .is_live = false },
    };

    const area = Rect{ .x = 0, .y = 0, .w = 500, .h = 400 };
    const tree = branch_tree.TreeLayout.compute(area, &items);

    try std.testing.expectEqual(@as(usize, 4), tree.count);
    // Nodes 0, 1, 2 are on active path
    try std.testing.expect(tree.nodes[0].is_active_path);
    try std.testing.expect(tree.nodes[1].is_active_path);
    try std.testing.expect(tree.nodes[2].is_active_path);
    // Node 3 is NOT on active path
    try std.testing.expect(!tree.nodes[3].is_active_path);
}

test "branch tree: hit test switch branch action" {
    const items = [_]Item{
        .{ .id = 0, .parent = 0, .fork_r = 0, .end_r = 100, .is_live = true },
        .{ .id = 1, .parent = 0, .fork_r = 50, .end_r = 80, .is_live = false },
    };

    const area = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const tree = branch_tree.TreeLayout.compute(area, &items);

    // Clicking on node 0 (live) returns .none
    const act0 = branch_tree.hit(area, &items, tree.nodes[0].rect.x + 10, tree.nodes[0].rect.y + 10);
    try std.testing.expectEqual(branch_tree.Action.none, act0);

    // Clicking on node 1 switch button returns switch_branch = 1
    const act1 = branch_tree.hit(area, &items, tree.nodes[1].switch_rect.x + 5, tree.nodes[1].switch_rect.y + 5);
    try std.testing.expectEqual(branch_tree.Action{ .switch_branch = 1 }, act1);

    // Clicking outside returns .none
    const act_out = branch_tree.hit(area, &items, 500, 500);
    try std.testing.expectEqual(branch_tree.Action.none, act_out);
}

test "branch tree: renders with paint table without panic" {
    const items = [_]Item{
        .{ .id = 0, .parent = 0, .fork_r = 0, .end_r = 100, .is_live = false },
        .{ .id = 1, .parent = 0, .fork_r = 50, .end_r = 80, .is_live = true },
    };

    const width: u32 = 400;
    const height: u32 = 300;
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, width, height);
    defer frame.deinit(std.testing.allocator);

    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    const area = Rect{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) };

    branch_tree.draw(&paint, dark, area, &items);
    raster.draw(&frame, &list, font.atlas);
}
