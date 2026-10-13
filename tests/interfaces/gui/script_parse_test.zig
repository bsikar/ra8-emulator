//! Tests for GUI action script parsing (RA8EMU-1120).
const std = @import("std");
const script = @import("gui_app").script;

test "parse timing variants: ms, s, and frames" {
    const text =
        \\# comment line
        \\at 500ms click 100 200
        \\// another comment
        \\at 1.5s click 150 250
        \\at frame 30 click 300 400
        \\at 0ms quit
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 4), parsed.items.items.len);

    const item0 = parsed.items.items[0];
    try std.testing.expectEqual(script.action.TimeSpec{ .time_ns = 500 * std.time.ns_per_ms }, item0.at);
    try std.testing.expectEqual(100, item0.action.click.coord.x);
    try std.testing.expectEqual(200, item0.action.click.coord.y);

    const item1 = parsed.items.items[1];
    try std.testing.expectEqual(script.action.TimeSpec{ .time_ns = 1500 * std.time.ns_per_ms }, item1.at);
    try std.testing.expectEqual(150, item1.action.click.coord.x);
    try std.testing.expectEqual(250, item1.action.click.coord.y);

    const item2 = parsed.items.items[2];
    try std.testing.expectEqual(script.action.TimeSpec{ .frame = 30 }, item2.at);
    try std.testing.expectEqual(300, item2.action.click.coord.x);
    try std.testing.expectEqual(400, item2.action.click.coord.y);

    const item3 = parsed.items.items[3];
    try std.testing.expectEqual(script.action.Action.quit, item3.action);
}

test "parse named click targets" {
    const text =
        \\at 1s click bar:run
        \\at 2s click bar:pause
        \\at 3s click bar:step
        \\at 4s click bar:speed
        \\at 5s click camera:allow_once
        \\at 6s click camera:always
        \\at 7s click camera:cam
        \\at 8s click camera:grd
        \\at 9s click board:sw1
        \\at 10s click board:sw2
        \\at 11s click board:touch 120 240
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 11), parsed.items.items.len);
    try std.testing.expectEqual(script.action.NamedTarget.bar_run, parsed.items.items[0].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.bar_pause, parsed.items.items[1].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.bar_step, parsed.items.items[2].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.bar_speed, parsed.items.items[3].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_allow_once, parsed.items.items[4].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_always, parsed.items.items[5].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_cam, parsed.items.items[6].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_grd, parsed.items.items[7].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.board_sw1, parsed.items.items[8].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.board_sw2, parsed.items.items[9].action.click.named);
    try std.testing.expectEqual(@as(u16, 120), parsed.items.items[10].action.click.touch.x);
    try std.testing.expectEqual(@as(u16, 240), parsed.items.items[10].action.click.touch.y);
}

test "parse drag, type, and keys" {
    const text =
        \\at 500ms drag 10 20 110 220 300
        \\at 1s type "hello world"
        \\at 1.5s key Return
        \\at 2s key Escape
        \\at 2.5s key Space
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 5), parsed.items.items.len);

    const d = parsed.items.items[0].action.drag;
    try std.testing.expectEqual(10, d.from_x);
    try std.testing.expectEqual(20, d.from_y);
    try std.testing.expectEqual(110, d.to_x);
    try std.testing.expectEqual(220, d.to_y);
    try std.testing.expectEqual(300, d.duration_ms);

    try std.testing.expectEqualStrings("hello world", parsed.items.items[1].action.type_text);
    try std.testing.expectEqual(@as(u32, 13), parsed.items.items[2].action.key.code);
    try std.testing.expectEqual(@as(u32, 27), parsed.items.items[3].action.key.code);
    try std.testing.expectEqual(@as(u32, 32), parsed.items.items[4].action.key.code);
}

test "parse error conditions" {
    try std.testing.expectError(error.BadTiming, script.parser.parse(std.testing.allocator, "at abc click 1 2"));
    try std.testing.expectError(error.BadAction, script.parser.parse(std.testing.allocator, "at 1s dance"));
    try std.testing.expectError(error.BadTarget, script.parser.parse(std.testing.allocator, "at 1s click nonexistent:target"));
    try std.testing.expectError(error.BadCoordinates, script.parser.parse(std.testing.allocator, "at 1s click"));
}
