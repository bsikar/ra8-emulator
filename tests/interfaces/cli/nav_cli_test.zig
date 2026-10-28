//! CLI ctl parsing and dispatch tests for navigation and reverse play (Slice 22.4).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const ctl = cli_app.session_ctl;
const ctl_nav = cli_app.ctl.nav;
const proto = ra8.rpc.session.rpc;

test "ctl_nav parsePlay parses directions and speeds" {
    const p1 = try ctl_nav.parsePlay(&.{"--dir=back"});
    try std.testing.expectEqual(proto.Direction.back, p1.dir);
    try std.testing.expectEqual(@as(?f64, null), p1.speed);

    const p2 = try ctl_nav.parsePlay(&.{"--dir=backward"});
    try std.testing.expectEqual(proto.Direction.back, p2.dir);

    const p3 = try ctl_nav.parsePlay(&.{"--dir=fwd"});
    try std.testing.expectEqual(proto.Direction.fwd, p3.dir);

    const p4 = try ctl_nav.parsePlay(&.{"--dir=forward"});
    try std.testing.expectEqual(proto.Direction.fwd, p4.dir);

    const p5 = try ctl_nav.parsePlay(&.{"--speed=2.5"});
    try std.testing.expectEqual(proto.Direction.fwd, p5.dir);
    try std.testing.expectEqual(@as(?f64, 2.5), p5.speed);

    const p6 = try ctl_nav.parsePlay(&.{ "back", "1.5" });
    try std.testing.expectEqual(proto.Direction.back, p6.dir);
    try std.testing.expectEqual(@as(?f64, 1.5), p6.speed);

    try std.testing.expectError(error.BadArguments, ctl_nav.parsePlay(&.{"--dir=sideways"}));
    try std.testing.expectError(error.BadArguments, ctl_nav.parsePlay(&.{"--speed=fast"}));
}

test "ctl_nav parseSeek normalizes multi-word seek targets" {
    const allocator = std.testing.allocator;

    const s1 = try ctl_nav.parseSeek(allocator, &.{ "frame", "42" });
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("frame 42", s1);

    const s2 = try ctl_nav.parseSeek(allocator, &.{ "iter", "10" });
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("iter 10", s2);

    const s3 = try ctl_nav.parseSeek(allocator, &.{ "marker", "boot_done" });
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("bm boot_done", s3);

    const s4 = try ctl_nav.parseSeek(allocator, &.{"0.5s"});
    try std.testing.expectEqualStrings("0.5s", s4);

    try std.testing.expectError(error.BadArguments, ctl_nav.parseSeek(allocator, &.{}));
}

test "ctl parse: play and seek commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "ra8", "ctl", "--connect", "unix:/s" };

    const play_back = try ctl.parse(a, &(base ++ [_][]const u8{ "play", "--dir=back" }));
    try std.testing.expectEqual(proto.Direction.back, play_back.command.play.dir);

    const play_speed = try ctl.parse(a, &(base ++ [_][]const u8{ "play", "--dir=fwd", "--speed=0.5" }));
    try std.testing.expectEqual(proto.Direction.fwd, play_speed.command.play.dir);
    try std.testing.expectEqual(@as(?f64, 0.5), play_speed.command.play.speed);

    const seek_frame = try ctl.parse(a, &(base ++ [_][]const u8{ "seek", "frame", "12" }));
    try std.testing.expectEqualStrings("frame 12", seek_frame.command.seek);

    const seek_iter = try ctl.parse(a, &(base ++ [_][]const u8{ "seek", "iter", "4" }));
    try std.testing.expectEqualStrings("iter 4", seek_iter.command.seek);

    const seek_marker = try ctl.parse(a, &(base ++ [_][]const u8{ "seek", "marker", "init" }));
    try std.testing.expectEqualStrings("bm init", seek_marker.command.seek);

    const direct_frame = try ctl.parse(a, &(base ++ [_][]const u8{ "frame", "12" }));
    try std.testing.expectEqualStrings("frame 12", direct_frame.command.seek);

    const direct_iter = try ctl.parse(a, &(base ++ [_][]const u8{ "iter", "4" }));
    try std.testing.expectEqualStrings("iter 4", direct_iter.command.seek);

    const direct_marker = try ctl.parse(a, &(base ++ [_][]const u8{ "marker", "init" }));
    try std.testing.expectEqualStrings("bm init", direct_marker.command.seek);
}

test "ctl parse: marker set and the Nth arrival of a marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "ra8", "ctl", "--connect", "unix:/s" };

    const armed = try ctl.parse(a, &(base ++ [_][]const u8{ "marker", "set", "loop", "main" }));
    try std.testing.expectEqualStrings("loop", armed.command.marker_set.name);
    try std.testing.expectEqualStrings("main", armed.command.marker_set.place);

    const nth = try ctl.parse(a, &(base ++ [_][]const u8{ "seek", "marker", "loop", "2" }));
    try std.testing.expectEqualStrings("marker loop 2", nth.command.seek);
}
