//! Covers src/snapshot/stretch.zig (RA8EMU-700).
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;
const stretch = ra8.snapshot.stretch;

test "what a run owed comes back from its section" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try stretch.save(123_456, stream.writer());
    try std.testing.expectEqual(@as(u32, 123_456), try stretch.load(stream.getWritten()));
}

test "a file with no stretch section owes nothing" {
    var buf: [16]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try std.testing.expectEqual(@as(u32, 0), try stretch.load(stream.getWritten()));
}

test "a stretch section of the wrong size is refused" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try file.writeHeader(stream.writer());
    try file.writeSectionHeader(stream.writer(), .stretch, 2);
    try stream.writer().writeAll(&.{ 1, 2 });
    try std.testing.expectError(error.BadValue, stretch.load(stream.getWritten()));
}
