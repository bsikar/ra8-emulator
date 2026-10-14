//! Tests for src/interfaces/gui/frame_pacer.zig: frames keep to a schedule
//! that a late start does not push back, a window far behind starts over,
//! and the meter reports what was drawn over half a second.
const std = @import("std");
const gui_app = @import("gui_app");

const frame_pacer = gui_app.frame_pacer;
const Pacer = frame_pacer.Pacer;
const Meter = frame_pacer.Meter;
const ms = std.time.ns_per_ms;

test "the first frame owes nothing known, and each later one the time since the last" {
    var pacer: Pacer = .{};
    try std.testing.expectEqual(@as(?u64, null), pacer.begin(5 * ms));
    try std.testing.expectEqual(@as(?u64, 4 * ms), pacer.begin(9 * ms));
    try std.testing.expectEqual(@as(?u64, 16 * ms), pacer.begin(25 * ms));
}

test "frames keep to the schedule when one begins a little late" {
    var pacer: Pacer = .{};
    const interval = 10 * ms;
    try std.testing.expectEqual(110 * ms, pacer.next(100 * ms, interval));
    // The wait overshot by half a millisecond: the frame after is not pushed back.
    try std.testing.expectEqual(120 * ms, pacer.next(110 * ms + ms / 2, interval));
    try std.testing.expectEqual(130 * ms, pacer.next(120 * ms + ms / 2, interval));
}

test "a frame that ran over begins the next at once, still on the schedule" {
    var pacer: Pacer = .{};
    const interval = 10 * ms;
    _ = pacer.next(100 * ms, interval);
    // Began at 115: its slot ended at 120, already close.
    const due = pacer.next(115 * ms, interval);
    try std.testing.expectEqual(120 * ms, due);
}

test "a window more than a frame behind starts its schedule over" {
    var pacer: Pacer = .{};
    const interval = 10 * ms;
    _ = pacer.next(100 * ms, interval);
    try std.testing.expectEqual(510 * ms, pacer.next(500 * ms, interval));
}

test "a shorter interval takes effect at once, and none is no wait" {
    var pacer: Pacer = .{};
    _ = pacer.next(100 * ms, 100 * ms);
    try std.testing.expectEqual(205 * ms, pacer.next(200 * ms, 5 * ms));
    try std.testing.expectEqual(207 * ms, pacer.next(207 * ms, 0));
    // After running unpaced the schedule starts from the frame at hand.
    try std.testing.expectEqual(220 * ms, pacer.next(210 * ms, 10 * ms));
}

test "the meter reports frames a second and a frame's cost every half second" {
    var meter: Meter = .{};
    var reading: ?Meter.Reading = null;
    var began: u64 = 0;
    // 100 frames a second, each two milliseconds of work.
    while (reading == null) : (began += 10 * ms) reading = meter.count(began, began + 2 * ms);
    try std.testing.expectEqual(@as(u32, 1000), reading.?.fps_tenths);
    try std.testing.expectEqual(@as(u32, 2000), reading.?.frame_us);
    try std.testing.expectEqual(frame_pacer.report_ns + 10 * ms, began);
    // It starts over from the frame it reported on.
    try std.testing.expectEqual(@as(?Meter.Reading, null), meter.count(began, began + ms));
}
