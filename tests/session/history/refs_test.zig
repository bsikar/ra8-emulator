//! Covers src/session/history/refs.zig: the committed frame walk that
//! reports the object names the checkpoint records carry (the saved
//! machine, its touched pages and its manifest), mandatory bits aside,
//! and stops at a torn tail.
const std = @import("std");
const ra8 = @import("ra8");
const refs = ra8.session.history_refs;
const format = ra8.session.history_format;

const digest = [16]u8{ 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

fn checkpointFrame(writer: anytype, kind: u16) !void {
    var payload: [24]u8 = undefined;
    // A record header's bytes, then the checkpoint id, then the digest.
    @memcpy(payload[0..4], "hdr!");
    std.mem.writeInt(u32, payload[4..8], 7, .little);
    @memcpy(payload[8..24], &digest);
    try format.encode(writer, kind, &payload);
}

fn hexName(buffer: *[32]u8) void {
    for (digest, 0..) |byte, i| {
        _ = std.fmt.bufPrint(buffer[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }
}

const Collector = struct {
    count: usize = 0,
    names: [4][32]u8 = undefined,

    fn visit(self: *Collector, name: refs.Name) void {
        if (self.count < self.names.len) self.names[self.count] = name;
        self.count += 1;
    }
};

/// The names one checkpoint record carries.
const per_checkpoint: usize = 3;

fn scanned(kind: u16, tail: []const u8) !Collector {
    var buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try checkpointFrame(&stream, kind);
    try stream.writeAll(tail);
    var seen = Collector{};
    try refs.scanCheckpointObjects(stream.buffered(), &seen, Collector.visit);
    return seen;
}

test "the walk reports a checkpoint record's machine, touched-pages and manifest names" {
    const seen = try scanned(@backingInt(@import("ra8").session.history_record.Kind.checkpoint), "");
    try std.testing.expectEqual(per_checkpoint, seen.count);
    var want: [32]u8 = undefined;
    hexName(&want);
    try std.testing.expectEqualSlices(u8, &want, &seen.names[0]);
    try std.testing.expectEqualSlices(u8, &ra8.session.history_touched_pages.objectName(digest), &seen.names[1]);
    try std.testing.expectEqualSlices(u8, &ra8.session.history_manifest.objectName(digest), &seen.names[2]);
}

test "the walk reads the mandatory bit as decoration" {
    const seen = try scanned(@backingInt(@import("ra8").session.history_record.Kind.checkpoint) | 0x8000, "");
    try std.testing.expectEqual(per_checkpoint, seen.count);
}

test "the walk skips other kinds" {
    const seen = try scanned(1, "");
    try std.testing.expectEqual(@as(usize, 0), seen.count);
    const unknown = try scanned(9, "");
    try std.testing.expectEqual(@as(usize, 0), unknown.count);
}

test "the walk stops at a torn tail" {
    const seen = try scanned(@backingInt(@import("ra8").session.history_record.Kind.checkpoint), "\x00\x00\x00");
    try std.testing.expectEqual(per_checkpoint, seen.count);
}
