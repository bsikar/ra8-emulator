//! Tests for script runner and event driving (RA8EMU-1120).
const std = @import("std");
const gui_app = @import("gui_app");
const script = gui_app.script;
const pane_layout = gui_app.pane_layout;

test "runner generates pointer and button events for click" {
    const text =
        \\at 100ms click 250 350
    ;
    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    var runner = script.runner.Runner.init(std.testing.allocator, parsed.items.items, false);
    defer runner.deinit();

    var layout = try pane_layout.twoCore(std.testing.allocator);
    defer layout.deinit();

    // At 50ms: nothing yet
    try runner.advance(&layout, 1024, 768, null, 50 * std.time.ns_per_ms, 3);
    try std.testing.expectEqual(@as(?script.runner.Event, null), runner.poll());

    // At 100ms: executes click
    try runner.advance(&layout, 1024, 768, null, 100 * std.time.ns_per_ms, 6);

    const ev1 = runner.poll();
    try std.testing.expect(ev1 != null);
    try std.testing.expectEqual(250, ev1.?.pointer.x);
    try std.testing.expectEqual(350, ev1.?.pointer.y);

    const ev2 = runner.poll();
    try std.testing.expect(ev2 != null);
    try std.testing.expectEqual(true, ev2.?.button.down);
    try std.testing.expectEqual(250, ev2.?.button.x);

    const ev3 = runner.poll();
    try std.testing.expect(ev3 != null);
    try std.testing.expectEqual(false, ev3.?.button.down);
    try std.testing.expectEqual(250, ev3.?.button.x);

    try std.testing.expectEqual(@as(?script.runner.Event, null), runner.poll());
}

test "runner generates multi-frame drag events" {
    const text =
        \\at 0ms drag 10 10 50 50 100
    ;
    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    var runner = script.runner.Runner.init(std.testing.allocator, parsed.items.items, false);
    defer runner.deinit();

    var layout = try pane_layout.twoCore(std.testing.allocator);
    defer layout.deinit();

    // Start of drag at 0ms: pointer + button down
    try runner.advance(&layout, 1024, 768, null, 0, 0);
    const ev_ptr = runner.poll();
    const ev_btn = runner.poll();
    try std.testing.expect(ev_ptr != null and ev_btn != null);
    try std.testing.expectEqual(10, ev_ptr.?.pointer.x);
    try std.testing.expectEqual(true, ev_btn.?.button.down);

    // Halfway at 50ms: interpolated pointer
    try runner.advance(&layout, 1024, 768, null, 50 * std.time.ns_per_ms, 3);
    const ev_mid = runner.poll();
    try std.testing.expect(ev_mid != null);
    try std.testing.expect(ev_mid.?.pointer.x > 10 and ev_mid.?.pointer.x < 50);

    // End at 100ms: pointer at destination + button up
    try runner.advance(&layout, 1024, 768, null, 100 * std.time.ns_per_ms, 6);
    const ev_end_ptr = runner.poll();
    const ev_end_btn = runner.poll();
    try std.testing.expect(ev_end_ptr != null and ev_end_btn != null);
    try std.testing.expectEqual(50, ev_end_ptr.?.pointer.x);
    try std.testing.expectEqual(50, ev_end_ptr.?.pointer.y);
    try std.testing.expectEqual(false, ev_end_btn.?.button.down);
}

test "headless auto-quit after cooldown" {
    const text =
        \\at 10ms key Space
    ;
    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    var runner = script.runner.Runner.init(std.testing.allocator, parsed.items.items, true);
    defer runner.deinit();
    runner.cooldown_frames = 5;

    var layout = try pane_layout.twoCore(std.testing.allocator);
    defer layout.deinit();

    // Frame 1: key executed
    try runner.advance(&layout, 1024, 768, null, 10 * std.time.ns_per_ms, 1);
    _ = runner.poll(); // key down
    _ = runner.poll(); // key up

    // Frames 2..5: cooldown waiting
    var f: u32 = 2;
    while (f < 6) : (f += 1) {
        try runner.advance(&layout, 1024, 768, null, @as(u64, f) * 16 * std.time.ns_per_ms, f);
        try std.testing.expectEqual(@as(?script.runner.Event, null), runner.poll());
    }

    // Frame 6 (1 + 5): quit event emitted
    try runner.advance(&layout, 1024, 768, null, 6 * 16 * std.time.ns_per_ms, 6);
    const ev_quit = runner.poll();
    try std.testing.expect(ev_quit != null);
    try std.testing.expectEqual(script.runner.Event.quit, ev_quit.?);
}

test "runner carries a modified key's modifiers into the events" {
    const text =
        \\at 0ms key shift+f5
    ;
    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    var runner = script.runner.Runner.init(std.testing.allocator, parsed.items.items, false);
    defer runner.deinit();

    var layout = try pane_layout.twoCore(std.testing.allocator);
    defer layout.deinit();

    try runner.advance(&layout, 1024, 768, null, 0, 0);

    const down = runner.poll();
    try std.testing.expect(down != null);
    try std.testing.expectEqual(script.action.KeyCode.f5, down.?.key.code);
    try std.testing.expectEqual(true, down.?.key.shift);
    try std.testing.expectEqual(false, down.?.key.primary);
    try std.testing.expectEqual(true, down.?.key.down);

    const up = runner.poll();
    try std.testing.expect(up != null);
    try std.testing.expectEqual(script.action.KeyCode.f5, up.?.key.code);
    try std.testing.expectEqual(false, up.?.key.down);
}
