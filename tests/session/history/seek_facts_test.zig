//! Covers src/session/history/seek_facts.zig: one walk over a committed
//! log gathers every checkpoint it names in order and the furthest round
//! its records reach, and an empty log gathers neither.

const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.session.history_format;
const record = ra8.session.history_record;
const seek_facts = ra8.session.history_seek_facts;
const scheduler = ra8.chip.core.scheduler;

fn at(r: u64, seq: u32) record.Header {
    return .{ .position = .{ .branch = 1, .r = r, .phase = .cpu0, .o = 0, .gap = .retired }, .seq = seq };
}

/// One record's payload through its own codec, wrapped in a frame.
fn frame(out: *std.Io.Writer, kind: u16, payload: []const u8) !void {
    try format.encode(out, kind, payload);
}

/// Encodes one checkpoint record into the log and returns the object.
fn checkpoint(out: *std.Io.Writer, payload: *std.Io.Writer.Allocating, r: u64, seq: u32, id: u32) ![16]u8 {
    var object: [16]u8 = undefined;
    for (&object, 0..) |*byte, i| byte.* = @truncate(r + i);
    payload.clearRetainingCapacity();
    try record.encodeCheckpoint(&payload.writer, at(r, seq), .{ .id = id, .object = object });
    try frame(out, @backingInt(record.Kind.checkpoint), payload.writer.buffered());
    return object;
}

test "one walk gathers the log's checkpoints in order and its furthest round" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();

    try frame(&buf.writer, @backingInt(record.Kind.root), "root-bytes");
    try record.encodeBranch(&payload.writer, at(4, 7), .{ .id = 2, .parent = 1, .fork_at = at(4, 7).position, .reason = .writes });
    try frame(&buf.writer, @backingInt(record.Kind.branch), payload.writer.buffered());
    const first = try checkpoint(&buf.writer, &payload, 4, 8, 9);
    payload.clearRetainingCapacity();
    try record.encodeBoundary(&payload.writer, at(5, 9), .{ .what = .c6_bytes, .body = "hi" });
    try frame(&buf.writer, @backingInt(record.Kind.boundary), payload.writer.buffered());
    const second = try checkpoint(&buf.writer, &payload, 7, 10, 11);

    const facts = try seek_facts.gather(std.testing.allocator, buf.writer.buffered());
    defer std.testing.allocator.free(facts.checkpoints);
    try std.testing.expectEqual(@as(usize, 2), facts.checkpoints.len);
    try std.testing.expectEqual(@as(u32, 9), facts.checkpoints[0].id);
    try std.testing.expectEqual(@as(u64, 4), facts.checkpoints[0].position.r);
    try std.testing.expectEqualSlices(u8, &first, &facts.checkpoints[0].object);
    try std.testing.expectEqual(@as(u32, 11), facts.checkpoints[1].id);
    try std.testing.expectEqual(@as(u64, 7), facts.checkpoints[1].position.r);
    try std.testing.expectEqualSlices(u8, &second, &facts.checkpoints[1].object);
    try std.testing.expectEqual(@as(u64, 7), facts.head_r);
}

test "a log with no checkpoint and no positioned record gathers neither" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try frame(&buf.writer, @backingInt(record.Kind.root), "root-bytes");

    const facts = try seek_facts.gather(std.testing.allocator, buf.writer.buffered());
    defer std.testing.allocator.free(facts.checkpoints);
    try std.testing.expectEqual(@as(usize, 0), facts.checkpoints.len);
    try std.testing.expectEqual(@as(u64, 0), facts.head_r);
}
