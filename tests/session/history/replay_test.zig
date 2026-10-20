//! Covers src/session/history/replay.zig: the read-back walk decodes a
//! committed log's records in order, skips an unknown kind nobody
//! requires, refuses an unknown mandatory kind, and stops at a torn
//! tail with the recovery facts log.zig's scan reports.
const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.session.history_format;
const record = ra8.session.history_record;
const replay_mod = ra8.session.history_replay;
const scheduler = ra8.chip.core.scheduler;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn baseHeader(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

/// One visited record, kept as the kind byte so the order assertions
/// stay readable.
const Which = enum(u8) { root, branch, checkpoint, intervention, boundary };

const Collector = struct {
    order: [8]Which = undefined,
    seen: usize = 0,
    frames: usize = 0,
    last_object: [16]u8 = undefined,
    last_id: u32 = 0,
    last_seq: u32 = 0,
    last_reason: record.ForkReason = .base,

    fn see(self: *Collector, entry: replay_mod.Entry) anyerror!void {
        switch (entry) {
            .root => {
                self.push(.root);
            },
            .branch => |hit| {
                self.push(.branch);
                self.last_seq = hit.header.seq;
                self.last_reason = hit.branch.reason;
            },
            .checkpoint => |hit| {
                self.push(.checkpoint);
                self.last_id = hit.checkpoint.id;
                self.last_object = hit.checkpoint.object;
            },
            .intervention => {
                self.push(.intervention);
            },
            .boundary => {
                self.push(.boundary);
            },
        }
    }

    fn push(self: *Collector, which: Which) void {
        self.order[self.seen] = which;
        self.seen += 1;
    }
};

/// Encodes one record's payload through its own codec, then wraps it in
/// a frame of `kind`.
fn frame(out: *std.Io.Writer, kind: u16, payload: []const u8) !void {
    try format.encode(out, kind, payload);
}

test "the read-back walk decodes a committed log's records in order" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();

    try frame(&buf.writer, @backingInt(record.Kind.root), "root-bytes");

    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    try record.encodeBranch(&payload.writer, baseHeader(7), .{ .id = 2, .parent = 1, .fork_at = base, .reason = .writes });
    try frame(&buf.writer, @backingInt(record.Kind.branch), payload.writer.buffered());

    var object: [16]u8 = undefined;
    for (&object, 0..) |*byte, i| byte.* = @intCast(i);
    payload.clearRetainingCapacity();
    try record.encodeCheckpoint(&payload.writer, baseHeader(8), .{ .id = 9, .object = object });
    try frame(&buf.writer, @backingInt(record.Kind.checkpoint), payload.writer.buffered());

    payload.clearRetainingCapacity();
    try record.encodeBoundary(&payload.writer, baseHeader(9), .{ .what = .c6_bytes, .body = "hi" });
    try frame(&buf.writer, @backingInt(record.Kind.boundary), payload.writer.buffered());

    var got: Collector = .{};
    const recovery = try replay_mod.replay(buf.writer.buffered(), &got, Collector.see);
    try std.testing.expectEqual(@as(usize, 4), got.seen);
    try std.testing.expectEqual(Which.root, got.order[0]);
    try std.testing.expectEqual(Which.branch, got.order[1]);
    try std.testing.expectEqual(Which.checkpoint, got.order[2]);
    try std.testing.expectEqual(Which.boundary, got.order[3]);
    try std.testing.expectEqual(@as(u32, 7), got.last_seq);
    try std.testing.expectEqual(record.ForkReason.writes, got.last_reason);
    try std.testing.expectEqual(@as(u32, 9), got.last_id);
    try std.testing.expectEqualSlices(u8, &object, &got.last_object);
    try std.testing.expectEqual(@as(usize, 4), recovery.frames);
    try std.testing.expectEqual(buf.writer.buffered().len, recovery.complete_end);
    try std.testing.expect(!recovery.torn);
}

test "an unknown kind nobody requires is skipped and still counted" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    try record.encodeIntervention(&payload.writer, baseHeader(11), .{ .what = .tap, .body = "x" });
    try frame(&buf.writer, @backingInt(record.Kind.intervention), payload.writer.buffered());
    try frame(&buf.writer, 0x1234, "future");
    var got: Collector = .{};
    const recovery = try replay_mod.replay(buf.writer.buffered(), &got, Collector.see);
    try std.testing.expectEqual(@as(usize, 1), got.seen);
    try std.testing.expectEqual(Which.intervention, got.order[0]);
    try std.testing.expectEqual(@as(usize, 2), recovery.frames);
    try std.testing.expect(!recovery.torn);
}

test "an unknown mandatory kind is refused" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try frame(&buf.writer, record.mandatory_bit | 0x1234, "required");
    var got: Collector = .{};
    try std.testing.expectError(error.UnknownMandatory, replay_mod.replay(buf.writer.buffered(), &got, Collector.see));
}

test "a torn tail stops the walk at the recovery point" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try frame(&buf.writer, @backingInt(record.Kind.root), "root-bytes");
    try frame(&buf.writer, @backingInt(record.Kind.boundary), "");
    const whole = buf.writer.buffered();
    const torn = whole[0 .. whole.len - 3];

    var got: Collector = .{};
    const recovery = try replay_mod.replay(torn, &got, Collector.see);
    try std.testing.expectEqual(@as(usize, 1), got.seen);
    try std.testing.expectEqual(@as(usize, 1), recovery.frames);
    try std.testing.expectEqual(@as(usize, format.header_len + "root-bytes".len), recovery.complete_end);
    try std.testing.expect(recovery.torn);
}
