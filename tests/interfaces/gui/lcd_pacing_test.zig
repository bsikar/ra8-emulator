//! Host tests for the LCD pane's pacing model (RA8EMU-824): at 100x the
//! newest frame shows at most at the refresh cap with the skipped ones
//! counted, at 0.1x a 10-frame animation shows every frame in order none
//! dropped, presents never come closer than the cap, a frame whose scaled
//! slot has not come shows nothing, and a queue that fills drops its oldest.
const std = @import("std");
const gui_app = @import("gui_app");
const pacing = gui_app.lcd_pacing;

const cap: i128 = @intCast(std.time.ns_per_s / 60);

test "at 100x the newest frame shows at most at the cap" {
    var pacer: pacing.Pacer = .{ .milli = 100 * 1000 };
    // A 60 Hz guest panel at 100x: a frame every 166.7 us of wall clock.
    const frame_ns: i128 = @intCast(std.time.ns_per_s / 6000);
    var at: i128 = 0;
    var last: i128 = -cap;
    var shown: usize = 0;
    while (at < @as(i128, @intCast(std.time.ns_per_s))) : (at += frame_ns) {
        pacer.arrive(@intCast(at * 100), at);
        if (pacer.due(at)) |d| {
            try std.testing.expect(at - last >= cap);
            try std.testing.expectEqual(pacer.arrivals, d.generation);
            last = at;
            pacer.present(d.generation, at);
            shown += 1;
        }
    }
    try std.testing.expect(shown >= 59 and shown <= 62);
    try std.testing.expectEqual(@as(u64, 6001), pacer.arrivals);
}

test "at 0.1x every frame of a 10-frame animation shows in order" {
    var pacer: pacing.Pacer = .{ .milli = 100 };
    const guest_ns: u64 = std.time.ns_per_ms * 10;
    const wall_ns: u64 = guest_ns * 10;
    var shown: u64 = 0;
    var arrived: usize = 0;
    var now: i128 = 0;
    while (now <= @as(i128, @intCast(2 * std.time.ns_per_s))) : (now += @intCast(std.time.ns_per_ms)) {
        // A frame lands every 100 ms of wall clock; the sweep drives both.
        if (arrived < 10 and @as(u64, @intCast(now)) >= arrived * wall_ns) {
            pacer.arrive(@intCast(arrived * guest_ns), now);
            arrived += 1;
        }
        if (pacer.due(now)) |d| {
            try std.testing.expectEqual(shown + 1, d.generation);
            try std.testing.expectEqual(@as(u64, 0), d.skipped);
            pacer.present(d.generation, now);
            shown += 1;
        }
    }
    try std.testing.expectEqual(@as(u64, 10), shown);
}

test "at 100x a burst past the queue skips everything before the newest" {
    var pacer: pacing.Pacer = .{ .milli = 100 * 1000 };
    for (0..12) |i| pacer.arrive(@intCast(i), @intCast(i));
    const d = pacer.due(12).?;
    try std.testing.expectEqual(@as(u64, 12), d.generation);
    try std.testing.expectEqual(@as(u64, 11), d.skipped);
    pacer.present(d.generation, 12);
    try std.testing.expectEqual(@as(usize, 0), pacer.count);
}

test "presents never come closer than the cap" {
    var pacer: pacing.Pacer = .{};
    pacer.arrive(0, 0);
    const d = pacer.due(0).?;
    try std.testing.expectEqual(@as(u64, 1), d.generation);
    try std.testing.expectEqual(@as(u64, 0), d.skipped);
    pacer.present(d.generation, 0);
    pacer.arrive(1, @intCast(cap - 1));
    try std.testing.expect(pacer.due(@intCast(cap - 1)) == null);
    const second = pacer.due(@intCast(cap)).?;
    try std.testing.expectEqual(@as(u64, 2), second.generation);
}

test "below 1x a frame whose scaled slot has not come shows nothing" {
    var pacer: pacing.Pacer = .{ .milli = 100 };
    pacer.arrive(0, 0);
    pacer.arrive(@intCast(std.time.ns_per_ms * 10), 0);
    const d = pacer.due(0).?;
    pacer.present(d.generation, 0);
    const mid: i128 = @intCast(std.time.ns_per_ms * 50);
    try std.testing.expect(pacer.due(mid) == null);
    const due: i128 = @intCast(std.time.ns_per_ms * 100);
    try std.testing.expectEqual(@as(u64, 2), pacer.due(due).?.generation);
}

test "a paused factor still shows queued frames in order" {
    var pacer: pacing.Pacer = .{ .milli = 0 };
    pacer.arrive(0, 0);
    pacer.arrive(5, 1);
    const d = pacer.due(2).?;
    try std.testing.expectEqual(@as(u64, 1), d.generation);
    pacer.present(d.generation, 2);
    try std.testing.expectEqual(@as(u64, 2), pacer.due(2 + cap).?.generation);
}
