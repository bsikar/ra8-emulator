//! Host tests for the history strip's click (slice 19): a recorded click
//! is consumed and the seek's refusal surfaces, a click off the strip or
//! on an empty track takes nothing, and the click's time text carries
//! the milliseconds a click's resolution holds.
const std = @import("std");
const gui_app = @import("gui_app");
const status_bar = gui_app.status.bar;
const history_strip = gui_app.history_strip;
const frame = gui_app.shell.frame;
const time_mod = gui_app.shell.time;
const session_link = gui_app.session_link;

const Time = time_mod.Time;
const Status = status_bar.Status;
const Rect = frame.Rect;

const strip = Rect{ .x = 0, .y = 100, .w = 480, .h = history_strip.height };

test "history strip click: a recorded click is consumed and the refusal surfaces" {
    var time: Time = .{ .track = .{ .end_ns = 10_000_000_000, .current_ns = 10_000_000_000 } };
    var status: Status = .{};
    var link = session_link.Link{};
    const mid = strip.x + strip.w / 2;
    try std.testing.expect(time.pressTrack(strip, mid, &status, &link));
    try std.testing.expectEqual(status_bar.Refusal.seek, status.refused.?);
}

test "history strip click: a click off the strip and an empty track take nothing" {
    var time: Time = .{};
    var status: Status = .{};
    var link = session_link.Link{};
    try std.testing.expect(!time.pressTrack(strip, strip.x + strip.w / 2, &status, &link));
    try std.testing.expect(status.refused == null);
    try std.testing.expect(!time.pressTrack(strip, strip.x - 1, &status, &link));
}

test "history strip click: with no clock reading the unrun tail takes nothing" {
    var time: Time = .{ .track = .{ .end_ns = 1_000_000_000, .current_ns = 1_000_000_000 } };
    var status: Status = .{};
    var link = session_link.Link{};
    const mid = strip.x + strip.w / 2;
    try std.testing.expect(time.pressTrack(strip, mid, &status, &link));
    try std.testing.expect(status.refused == null);
}

test "history strip click: a click in the unrun tail refuses on a link without a transport" {
    var time: Time = .{ .track = .{ .end_ns = 1_000_000_000, .current_ns = 1_000_000_000 } };
    time.readout.virtual_ns = 1_000_000_000;
    var status: Status = .{};
    var link = session_link.Link{};
    const mid = strip.x + strip.w / 2;
    try std.testing.expect(time.pressTrack(strip, mid, &status, &link));
    try std.testing.expect(status.refused == .advance);
}

test "history strip click: a click behind the clock's reading takes nothing" {
    var time: Time = .{ .track = .{ .end_ns = 1_000_000_000, .current_ns = 1_000_000_000 } };
    time.readout.virtual_ns = 20_000_000_000;
    var status: Status = .{};
    var link = session_link.Link{};
    const mid = strip.x + strip.w / 2;
    try std.testing.expect(time.pressTrack(strip, mid, &status, &link));
    try std.testing.expect(status.refused == null);
}

test "history track keys: Home and End seek over the same dispatch" {
    var time: Time = .{ .track = .{ .end_ns = 10_000_000_000, .current_ns = 10_000_000_000 } };
    var status: Status = .{};
    var link = session_link.Link{};
    const capture = gui_app.time.bar_capture;
    try std.testing.expect(time.trackKeyFull(capture.key_home, false, &status, &link));
    try std.testing.expectEqual(status_bar.Refusal.seek, status.refused.?);
    status.refused = null;
    try std.testing.expect(time.trackKeyFull(capture.key_end, false, &status, &link));
    try std.testing.expectEqual(status_bar.Refusal.seek, status.refused.?);
    try std.testing.expect(!time.trackKeyFull(capture.key_f5, false, &status, &link));
}

test "history track keys: an empty track takes nothing" {
    var time: Time = .{};
    var status: Status = .{};
    var link = session_link.Link{};
    const capture = gui_app.time.bar_capture;
    try std.testing.expect(!time.trackKeyFull(capture.key_home, false, &status, &link));
    try std.testing.expect(!time.trackKeyFull(capture.key_end, false, &status, &link));
    try std.testing.expect(status.refused == null);
}

test "history strip click: the click's time text carries milliseconds" {
    var buffer: [40]u8 = undefined;
    try std.testing.expectEqualStrings("1.500s", Time.timeText(&buffer, 1_500_000_000).?);
    try std.testing.expectEqualStrings("0.000s", Time.timeText(&buffer, 0).?);
}
