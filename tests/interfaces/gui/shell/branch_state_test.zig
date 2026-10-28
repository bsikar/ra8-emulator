//! Tests for src/interfaces/gui/shell/branch_state.zig (Slice 20.4).
const std = @import("std");
const ra8 = @import("ra8");
const proto = ra8.rpc.session.rpc;
const gui_app = @import("gui_app");
const branch_state = gui_app.shell.branch_state;
const fork_banner = gui_app.fork_banner;
const branch_list = gui_app.branch_list;

test "branch_state handles status and list updates and tracks confirmation state" {
    var state = branch_state.State{};

    // Handle status pending
    state.handleStatus(.{ .pending = 1, .reason = 1, .branch = 0, .r = 42 });
    try std.testing.expect(state.fork_pending);

    // Handle status not pending
    state.handleStatus(.{ .pending = 0, .reason = 0, .branch = 0, .r = 0 });
    try std.testing.expect(!state.fork_pending);

    // Handle branch list
    const items = [_]proto.BranchItem{
        .{
            .id = 0,
            .parent = 0,
            .fork_r = 0,
            .recorded_end_r = 100,
            .child_count = 1,
            .reason = 0,
            .flags = 1, // live
        },
        .{
            .id = 1,
            .parent = 0,
            .fork_r = 40,
            .recorded_end_r = 80,
            .child_count = 0,
            .reason = 1,
            .flags = 0,
        },
    };

    var wire_bytes: [2 * proto.branch_wire.item_bytes]u8 = undefined;
    for (items, 0..) |item, i| proto.branch_wire.put(&wire_bytes, i, item);
    state.handleList(.{ .count = 2, .bytes = &wire_bytes });
    try std.testing.expectEqual(@as(usize, 2), state.items_len);
    try std.testing.expectEqual(@as(u32, 0), state.items()[0].id);
    try std.testing.expect(state.items()[0].is_live);
    try std.testing.expectEqual(@as(u32, 1), state.items()[1].id);
    try std.testing.expect(!state.items()[1].is_live);

    // Delete request & confirmation tracking
    try state.onListAction(undefined, .{ .request_delete = 1 });
    try std.testing.expectEqual(@as(?u32, 1), state.confirming_id);

    try state.onListAction(undefined, .cancel_delete);
    try std.testing.expectEqual(@as(?u32, null), state.confirming_id);
}

test "branch feed notes: waiting, refused without history, listed" {
    var feed = branch_state.Feed{};
    try std.testing.expectEqualStrings("waiting for the branches", feed.note().?);
    feed.state.refused = true;
    try std.testing.expectEqualStrings("the session keeps no history", feed.note().?);
    feed.state.refused = false;
    feed.state.answered = true;
    try std.testing.expectEqualStrings("no branches recorded", feed.note().?);
    feed.state.items_len = 1;
    try std.testing.expect(feed.note() == null);
    feed.reload();
    try std.testing.expect(feed.state.want and !feed.state.answered and feed.state.items_len == 0);
}
