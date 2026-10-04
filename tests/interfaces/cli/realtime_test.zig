//! Tests for --realtime and the pace line (src/periph/time/pacing.zig).
const std = @import("std");
const ra8 = @import("ra8");
const parse = ra8.core.cli.parse;
const clocks = ra8.periph.clocks;
const realtime = clocks.pacing;

test "a run is unpaced unless it asks for --realtime" {
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(!plain.realtime);
    const paced = try parse(&[_][]const u8{ "emu", "a.elf", "--realtime" });
    try std.testing.expect(paced.realtime);
}

test "an unpaced run prints no pace line" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const time = clocks.Time{};
    try realtime.line(stream.writer(), &time);
    try std.testing.expectEqualStrings("", stream.getWritten());
}

test "the pace line gives requested and achieved speed, drift and slips" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try realtime.write(stream.writer(), .{
        .requested_milli = 1000,
        .achieved_milli = 987,
        .drift_ns = 12_345_678,
        .slips = 2,
        .slept_ns = 0,
    });
    try std.testing.expectEqualStrings(
        "pace: requested 1.000x, achieved 0.987x, drift 12.345 ms, 2 slips\n",
        stream.getWritten(),
    );
}

test "attaching paces the board's time from where it stands" {
    var time = clocks.Time{};
    time.base.advance(3_000);
    try realtime.attachHost(&time, 1000);
    const paced = time.pacing.?;
    try std.testing.expectEqual(@as(u64, 3_000), paced.last_ns);
    try std.testing.expectEqual(@as(u64, 1000), paced.pacer.speed_milli);
}
