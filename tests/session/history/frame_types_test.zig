//! Tests for src/session/history/frame_types.zig: wire encoding, decoding,
//! CRC-32C validation, and kind handling.
const std = @import("std");
const ra8 = @import("ra8");
const types = ra8.session.history_frame_types;

const test_pos = types.Position{
    .branch = 1,
    .r = 42,
    .phase = .cpu0,
    .o = 100,
    .gap = .retired,
};

test "FrameHeader encodes and decodes round-trip" {
    const header: types.FrameHeader = .{
        .kind = .keyframe,
        .position = test_pos,
        .virtual_ns = 1_000_000,
        .width = 1024,
        .height = 600,
        .rect = .{ .x = 0, .y = 0, .width = 1024, .height = 600 },
        .uncompressed_len = 614_400,
        .compressed_len = 12_345,
        .crc32c = 0x1234_5678,
    };
    var buf: [types.header_len]u8 = undefined;
    header.encode(&buf);

    const decoded = try types.FrameHeader.decode(&buf);
    try std.testing.expectEqual(header.kind, decoded.kind);
    try std.testing.expectEqual(header.position.r, decoded.position.r);
    try std.testing.expectEqual(header.position.branch, decoded.position.branch);
    try std.testing.expectEqual(header.virtual_ns, decoded.virtual_ns);
    try std.testing.expectEqual(header.width, decoded.width);
    try std.testing.expectEqual(header.height, decoded.height);
    try std.testing.expectEqual(header.rect.width, decoded.rect.width);
    try std.testing.expectEqual(header.uncompressed_len, decoded.uncompressed_len);
    try std.testing.expectEqual(header.compressed_len, decoded.compressed_len);
    try std.testing.expectEqual(header.crc32c, decoded.crc32c);
}

test "FrameRecord with payload encodes and decodes round-trip with CRC check" {
    const payload = "compressed_payload_sample_data_1234567890";
    const crc = types.FrameHeader.computeCrc(payload);
    const header: types.FrameHeader = .{
        .kind = .delta,
        .position = test_pos,
        .virtual_ns = 2_000_000,
        .width = 1024,
        .height = 600,
        .rect = .{ .x = 10, .y = 20, .width = 50, .height = 30 },
        .uncompressed_len = 1500,
        .compressed_len = @intCast(payload.len),
        .crc32c = crc,
    };
    const record: types.FrameRecord = .{ .header = header, .payload = payload };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try record.writeTo(&writer);

    var decoded = try types.FrameRecord.decode(std.testing.allocator, writer.buffered());
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.FrameKind.delta, decoded.header.kind);
    try std.testing.expectEqualStrings(payload, decoded.payload);
}

test "FrameRecord CRC corruption is rejected" {
    const payload = "valid_payload_data";
    const crc = types.FrameHeader.computeCrc(payload);
    const header: types.FrameHeader = .{
        .kind = .delta,
        .position = test_pos,
        .virtual_ns = 3_000_000,
        .width = 100,
        .height = 100,
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .uncompressed_len = 100,
        .compressed_len = @intCast(payload.len),
        .crc32c = crc,
    };
    const record: types.FrameRecord = .{ .header = header, .payload = payload };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try record.writeTo(&writer);

    // Corrupt one payload byte
    buf[types.header_len] ^= 0xFF;

    const err = types.FrameRecord.decode(std.testing.allocator, writer.buffered());
    try std.testing.expectError(types.Error.BadCrc, err);
}

test "regenerate_by_replay record has zero payload" {
    const header: types.FrameHeader = .{
        .kind = .regenerate_by_replay,
        .position = test_pos,
        .virtual_ns = 4_000_000,
        .width = 1024,
        .height = 600,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .uncompressed_len = 0,
        .compressed_len = 0,
        .crc32c = 0,
    };
    const record: types.FrameRecord = .{ .header = header, .payload = &.{} };

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try record.writeTo(&writer);

    var decoded = try types.FrameRecord.decode(std.testing.allocator, writer.buffered());
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.FrameKind.regenerate_by_replay, decoded.header.kind);
    try std.testing.expectEqual(@as(usize, 0), decoded.payload.len);
}

test "FrameSink receives borrowed FrameRecord" {
    const TestSink = struct {
        called: bool = false,
        received_kind: types.FrameKind = undefined,

        fn write(ctx: *anyopaque, record: *const types.FrameRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            self.received_kind = record.header.kind;
        }
    };

    var ts = TestSink{};
    const sink = types.FrameSink{
        .ctx = &ts,
        .writeFrameFn = TestSink.write,
    };

    const header: types.FrameHeader = .{
        .kind = .keyframe,
        .position = test_pos,
        .virtual_ns = 5_000_000,
        .width = 10,
        .height = 10,
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .uncompressed_len = 100,
        .compressed_len = 0,
        .crc32c = 0,
    };
    const record: types.FrameRecord = .{ .header = header, .payload = &.{} };
    try sink.writeFrame(&record);
    try std.testing.expect(ts.called);
    try std.testing.expectEqual(types.FrameKind.keyframe, ts.received_kind);
}
