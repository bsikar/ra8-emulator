//! Tests for named GUI control target resolution (RA8EMU-1120).
const std = @import("std");
const gui_app = @import("gui_app");
const script = gui_app.script;
const pane_layout = gui_app.pane_layout;
const shell = gui_app.shell;

test "resolve coordinate target" {
    const pt = script.target.resolve(
        std.testing.allocator,
        undefined,
        1024,
        768,
        null,
        .{ .coord = .{ .x = 123, .y = 456 } },
    );
    try std.testing.expect(pt != null);
    try std.testing.expectEqual(123, pt.?.x);
    try std.testing.expectEqual(456, pt.?.y);
}

test "resolve time bar controls: run, pause, step, speed" {
    const width: i32 = 1024;
    const height: i32 = 768;
    var layout = try pane_layout.twoCore(std.testing.allocator);
    defer layout.deinit();

    const pt_run = script.target.resolve(std.testing.allocator, &layout, width, height, null, .{ .named = .bar_run });
    const pt_pause = script.target.resolve(std.testing.allocator, &layout, width, height, null, .{ .named = .bar_pause });
    const pt_step = script.target.resolve(std.testing.allocator, &layout, width, height, null, .{ .named = .bar_step });
    const pt_speed = script.target.resolve(std.testing.allocator, &layout, width, height, null, .{ .named = .bar_speed });

    try std.testing.expect(pt_run != null);
    try std.testing.expect(pt_pause != null);
    try std.testing.expect(pt_step != null);
    try std.testing.expect(pt_speed != null);

    // Time bar is at the bottom of the window
    try std.testing.expect(pt_run.?.y > height - 60);
    try std.testing.expect(pt_pause.?.y > height - 60);
    try std.testing.expect(pt_step.?.y > height - 60);
    try std.testing.expect(pt_speed.?.y > height - 60);

    // Run is to the left of pause, pause is to the left of step
    try std.testing.expect(pt_run.?.x < pt_pause.?.x);
    try std.testing.expect(pt_pause.?.x < pt_step.?.x);
}

test "resolve board switches and touch" {
    const width: i32 = 1024;
    const height: i32 = 768;
    var layout = try pane_layout.twoCore(std.testing.allocator);
    defer layout.deinit();

    // twoCore has a board pane
    const pt_sw1 = script.target.resolve(std.testing.allocator, &layout, width, height, null, .{ .named = .board_sw1 });
    const pt_sw2 = script.target.resolve(std.testing.allocator, &layout, width, height, null, .{ .named = .board_sw2 });
    const pt_touch = script.target.resolve(std.testing.allocator, &layout, width, height, null, .{ .touch = .{ .x = 100, .y = 100 } });

    try std.testing.expect(pt_sw1 != null);
    try std.testing.expect(pt_sw2 != null);
    try std.testing.expect(pt_touch != null);

    // Coordinates are within window boundaries
    try std.testing.expect(pt_sw1.?.x >= 0 and pt_sw1.?.x < width);
    try std.testing.expect(pt_sw1.?.y >= 0 and pt_sw1.?.y < height);
    try std.testing.expect(pt_touch.?.x >= 0 and pt_touch.?.x < width);
    try std.testing.expect(pt_touch.?.y >= 0 and pt_touch.?.y < height);
}
