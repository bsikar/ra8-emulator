//! Host tests for the history track's model: the span the strip shows,
//! a click's classification across the recorded/unrun boundary and the
//! checkpoint a click resolves to.
const std = @import("std");
const gui_app = @import("gui_app");
const history_track = gui_app.history_track;

const second = std.time.ns_per_s;

test "history track: the tail past the end" {
    try std.testing.expectEqual(10 * second, history_track.pastEnd(10 * second));
    try std.testing.expectEqual(25 * second, history_track.pastEnd(100 * second));
    try std.testing.expectEqual(20 * second, history_track.spanTotal(10 * second));
    try std.testing.expectEqual(125 * second, history_track.spanTotal(100 * second));
}

test "history track: an empty track" {
    const track = history_track.Track{};
    try std.testing.expect(!track.recorded());
    try std.testing.expectEqual(@as(u64, 0), track.total());
    try std.testing.expectEqual(@as(?f64, null), track.cursorFraction());
    try std.testing.expectEqual(@as(?history_track.Click, null), track.click(0.5));
}

test "history track: a click across the boundary" {
    var track = history_track.Track{ .end_ns = 10 * second };
    try std.testing.expect(track.recorded());
    try std.testing.expectEqual(@as(u64, 20 * second), track.total());
    const inside = track.click(0.25).?;
    try std.testing.expectEqual(@as(u64, 5 * second), inside.recorded);
    const over = track.click(0.75).?;
    try std.testing.expectEqual(@as(u64, 15 * second), over.unrun);
    // The boundary itself is the recorded end, still a seek.
    const edge = track.click(0.5).?;
    try std.testing.expectEqual(@as(u64, 10 * second), edge.recorded);
    // Off the ends clamps to the edge.
    const low = track.click(-1.0).?;
    try std.testing.expectEqual(@as(u64, 0), low.recorded);
    const high = track.click(2.0).?;
    try std.testing.expectEqual(@as(u64, 20 * second), high.unrun);
}

test "history track: the cursor's fraction" {
    var track = history_track.Track{ .end_ns = 10 * second, .current_ns = 5 * second };
    try std.testing.expectEqual(@as(f64, 0.25), track.cursorFraction().?);
    track.current_ns = 40 * second;
    try std.testing.expectEqual(@as(f64, 1.0), track.cursorFraction().?);
    track.current_ns = null;
    try std.testing.expectEqual(@as(?f64, null), track.cursorFraction());
}

test "history track: the checkpoint a click resolves to" {
    const marks = [_]history_track.Mark{
        .{ .ns = 1 * second, .index = 0 },
        .{ .ns = 4 * second, .index = 1 },
        .{ .ns = 7 * second, .index = 2 },
    };
    const at_five = history_track.checkpointBefore(&marks, 5 * second).?;
    try std.testing.expectEqual(@as(u64, 4 * second), at_five.ns);
    try std.testing.expectEqual(@as(usize, 1), at_five.index);
    try std.testing.expectEqual(@as(?history_track.Mark, null), history_track.checkpointBefore(&marks, 500 * std.time.ns_per_ms));
    const late = history_track.checkpointBefore(&marks, 100 * second).?;
    try std.testing.expectEqual(@as(usize, 2), late.index);
    try std.testing.expectEqual(@as(?history_track.Mark, null), history_track.checkpointBefore(&.{}, 5 * second));
}
