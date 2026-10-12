//! Host tests for the board feed's pacing (RA8EMU-824): arrivals queue into
//! the feed's pacer, a frame shows at most once per refresh cap, everything
//! passed over rides along in `skipped`, and the view reports it for the
//! pane's corner.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const proto = ra8.rpc.session.rpc;
const board = gui_app.shell.board;
const link = gui_app.session_link;

/// Encode an lcd_dirty event stamped with its virtual time into `buf`, which
/// must outlive the observe that reads the payload.
fn pacedEvent(buf: []u8, virtual_ns: u64, grays: []const u8) link.Arrival {
    const encoded = proto.encode(proto.DirtyRect, .{
        .core = .cpu0,
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 2,
        .virtual_ns = virtual_ns,
        .pixels = grays,
    }, buf) catch unreachable;
    return .{ .event = .{ .topic = @backingInt(proto.Topic.lcd_dirty), .payload = encoded } };
}

test "at 100x the newest frame shows at the cap and the pass-overs count" {
    var feed = board.Board.init(std.testing.allocator);
    defer feed.deinit();
    const grays = [_]u8{ 5, 5, 5, 5 };
    var buf: [256]u8 = undefined;
    for (0..60) |frame| {
        try feed.observe(pacedEvent(&buf, @intCast(frame * 16_666_666), &grays), @intCast(frame * 166_666));
    }
    feed.pace(100_000_000);
    try std.testing.expectEqual(@as(u64, 60), feed.pacer.arrivals);
    try std.testing.expectEqual(@as(u64, 0), feed.pacer.count);
    try std.testing.expectEqual(@as(u64, 59), feed.skipped);
    const view = feed.view(null);
    try std.testing.expectEqual(@as(u64, 59), view.skipped);
}

test "at 0.1x each queued frame shows in order at its scaled slot" {
    var feed = board.Board.init(std.testing.allocator);
    defer feed.deinit();
    feed.pacer.milli = 100;
    const grays = [_]u8{ 9, 9, 9, 9 };
    var buf: [256]u8 = undefined;
    for (0..6) |frame| {
        try feed.observe(pacedEvent(&buf, @intCast(frame * 1_000_000), &grays), @intCast(frame * 100_000_000));
    }
    // Each frame's scaled slot is 10 ms after the last, and a present never
    // comes under the cap, so a pace at 17 ms multiples consumes exactly one
    // frame per pass, oldest first. Six frames fit the depth-8 ring; the
    // model tests cover the drop accounting past it.
    for (1..7) |pass| {
        feed.pace(@intCast(pass * 17_000_000));
        try std.testing.expectEqual(@as(usize, 6 - pass), feed.pacer.count);
        try std.testing.expectEqual(@as(u64, 0), feed.skipped);
    }
}
