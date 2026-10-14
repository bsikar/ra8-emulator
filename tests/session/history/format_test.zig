//! Covers src/session/history/format.zig: the log frame's frozen wire
//! rules, its hand-encoded vector, and what every truncation boundary and
//! bit flip answers.
const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.session.history_format;

const kind: u16 = 0x0102;
const payload = [_]u8{ 0xDE, 0xAD };

fn appended(buf: *std.Io.Writer.Allocating, frame_kind: u16, frame_payload: []const u8) ![]u8 {
    try format.encode(&buf.writer, frame_kind, frame_payload);
    return buf.written();
}

test "the bytes are the frozen layout, and a hand-encoded frame decodes" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    _ = try appended(&buf, kind, &payload);
    var expected: [10 + payload.len]u8 = undefined;
    std.mem.writeInt(u32, expected[0..4], payload.len, .little);
    std.mem.writeInt(u16, expected[4..6], kind, .little);
    std.mem.writeInt(u32, expected[6..10], format.crcOf(kind, &payload), .little);
    @memcpy(expected[10..], &payload);
    try std.testing.expectEqualSlices(u8, &expected, buf.written());

    const decoded = try format.decode(&expected);
    try std.testing.expectEqual(kind, decoded.frame.kind);
    try std.testing.expectEqualSlices(u8, &payload, decoded.frame.payload);
    try std.testing.expectEqual(expected.len, decoded.consumed);
}

test "a two-frame log survives every truncation with either whole frames or a torn tail" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    _ = try appended(&buf, 1, &payload);
    _ = try appended(&buf, 2, "hello");
    const bytes = buf.written();
    const first_end = format.header_len + payload.len;
    for (0..bytes.len + 1) |cut| {
        var cursor: usize = 0;
        var kinds: usize = 0;
        while (cursor < cut) {
            const hit = format.decode(bytes[cursor..cut]) catch |err| {
                // A torn tail is the only way the scan stops early; a hard
                // error here would mean a whole frame failed to decode.
                try std.testing.expectEqual(error.Truncated, err);
                break;
            };
            try std.testing.expectEqual(@as(u16, @intCast(kinds + 1)), hit.frame.kind);
            kinds += 1;
            cursor += hit.consumed;
        }
        try std.testing.expectEqual(kinds, if (cut >= first_end) @as(usize, 1) + @intFromBool(cut == bytes.len) else 0);
    }
}

test "every single-bit flip inside a whole frame is refused" {
    var frame: [format.header_len + payload.len]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], payload.len, .little);
    std.mem.writeInt(u16, frame[4..6], kind, .little);
    std.mem.writeInt(u32, frame[6..10], format.crcOf(kind, &payload), .little);
    @memcpy(frame[format.header_len..], &payload);
    for (0..frame.len) |at| for (0..8) |bit| {
        var broken = frame;
        broken[at] ^= @as(u8, 1) << @intCast(bit);
        if (format.decode(&broken)) |_| {
            return error.BitFlipAccepted;
        } else |err| switch (err) {
            error.Truncated, error.BadLength, error.BadCrc => {},
        }
    };
}

test "a length beyond the bound is refused before any payload is read" {
    var header: [10]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], format.max_len + 1, .little);
    std.mem.writeInt(u16, header[4..6], kind, .little);
    std.mem.writeInt(u32, header[6..10], format.crcOf(kind, ""), .little);
    try std.testing.expectError(error.BadLength, format.decode(&header));
    // A frame that claims the largest legal payload but stops short is a
    // torn tail, not a corruption.
    std.mem.writeInt(u32, header[0..4], format.max_len, .little);
    try std.testing.expectError(error.Truncated, format.decode(&header));
}
