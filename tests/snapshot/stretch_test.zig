//! Covers src/snapshot/stretch.zig (RA8EMU-700).
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;
const stretch = ra8.snapshot.stretch;

test "what a run owed comes back from its section" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try stretch.save(.{ .owed = 123_456, .cycle_remainder = 789, .boundary_hz = 8_000_000 }, stream.writer());
    const expected: stretch.State = .{ .owed = 123_456, .cycle_remainder = 789, .rate_known = true, .boundary_hz = 8_000_000 };
    try std.testing.expectEqual(expected, try stretch.load(stream.getWritten()));
}

test "an unscaled open boundary remains unscaled" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try stretch.save(.{ .owed = 123_456 }, stream.writer());
    const expected: stretch.State = .{ .owed = 123_456, .rate_known = true };
    try std.testing.expectEqual(expected, try stretch.load(stream.getWritten()));
}

test "a file with no stretch section owes nothing" {
    var buf: [16]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try std.testing.expectEqual(stretch.State{}, try stretch.load(stream.getWritten()));
}

test "an old stretch section loads without a fractional cycle" {
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try file.writeSectionHeader(stream.writer(), .stretch, @sizeOf(u32));
    try stream.writer().writeInt(u32, 123_456, .little);
    const expected: stretch.State = .{ .owed = 123_456, .rate_known = true };
    try std.testing.expectEqual(expected, try stretch.load(stream.getWritten()));
}

test "an old fractional stretch section loads without a boundary rate" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try file.writeSectionHeader(stream.writer(), .stretch, @sizeOf(u32) + @sizeOf(u64));
    try stream.writer().writeInt(u32, 123_456, .little);
    try stream.writer().writeInt(u64, 789, .little);
    const expected: stretch.State = .{ .owed = 123_456, .cycle_remainder = 789 };
    try std.testing.expectEqual(expected, try stretch.load(stream.getWritten()));
}

test "a stretch section of the wrong size is refused" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try file.writeSectionHeader(stream.writer(), .stretch, 2);
    try stream.writer().writeAll(&.{ 1, 2 });
    try std.testing.expectError(error.BadValue, stretch.load(stream.getWritten()));
}
