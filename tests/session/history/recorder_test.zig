//! Covers src/session/history/recorder.zig: boundary and intervention
//! frames reach the storage in order, a torn final tail recovers to the
//! last whole frame, and group commit fires on both thresholds.
const std = @import("std");
const ra8 = @import("ra8");
const recorder_mod = ra8.session.history_recorder;
const format = ra8.session.history_format;
const log_mod = ra8.session.history_log;
const record = ra8.session.history_record;
const scheduler = ra8.chip.core.scheduler;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn header(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

/// The in-memory storage a test fills: bytes land in one buffer, every
/// flush counts, and every truncation records the length it cut to.
const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    flushes: usize = 0,
    truncations: std.ArrayList(usize) = .empty,

    fn append(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.gpa, data);
    }

    fn flush(context: *anyopaque) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.flushes += 1;
    }

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
        try self.truncations.append(self.gpa, @intCast(len));
    }

    fn storage(self: *Sink) recorder_mod.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }
};

test "boundary and intervention frames land in order and decode back" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.recordIntervention(header(2), .{ .what = .tap, .body = "xy" });
    try std.testing.expectEqual(@as(usize, 0), sink.flushes);
    try rec.commit(1);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());

    var kinds: [8]u16 = undefined;
    var seqs: [8]u32 = undefined;
    var index: usize = 0;
    var cursor: usize = 0;
    while (cursor < sink.bytes.items.len) {
        const hit = try format.decode(sink.bytes.items[cursor..]);
        const frame = hit.frame;
        const payload = frame.payload;
        switch (frame.kind) {
            @backingInt(record.Kind.boundary) => {
                const boundary = try record.decodeBoundary(payload);
                kinds[index] = frame.kind;
                seqs[index] = boundary.header.seq;
                try std.testing.expectEqualStrings("abc", boundary.boundary.body);
            },
            @backingInt(record.Kind.intervention) => {
                const intervention = try record.decodeIntervention(payload);
                kinds[index] = frame.kind;
                seqs[index] = intervention.header.seq;
                try std.testing.expectEqualStrings("xy", intervention.intervention.body);
            },
            else => return error.UnexpectedKind,
        }
        index += 1;
        cursor += hit.consumed;
    }
    try std.testing.expectEqual(@as(usize, 2), index);
    try std.testing.expectEqual(@backingInt(record.Kind.boundary), kinds[0]);
    try std.testing.expectEqual(@as(u32, 1), seqs[0]);
    try std.testing.expectEqual(@backingInt(record.Kind.intervention), kinds[1]);
    try std.testing.expectEqual(@as(u32, 2), seqs[1]);
}

test "a torn final tail recovers to the last whole frame" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    defer sink.truncations.deinit(gpa);

    // One whole frame, then half of a second one's header.
    var whole: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer whole.deinit();
    try format.encode(&whole.writer, @backingInt(record.Kind.boundary), "\x00\x01ab");
    try sink.bytes.appendSlice(gpa, whole.writer.buffered());
    try sink.bytes.appendSlice(gpa, &[_]u8{ 0x09, 0x00, 0x00, 0x00, 0x01 });

    const recovery = try recorder_mod.recoverSegment(sink.bytes.items, sink.storage());
    try std.testing.expect(recovery.torn);
    try std.testing.expectEqual(@as(usize, 1), sink.truncations.items.len);
    try std.testing.expectEqual(whole.writer.buffered().len, sink.bytes.items.len);
    const hit = try format.decode(sink.bytes.items);
    try std.testing.expectEqual(@backingInt(record.Kind.boundary), hit.frame.kind);
}

test "group commit fires on the byte threshold and on the clock" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    // A one-frame byte threshold commits on the frame's back.
    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{ .max_bytes = 16, .max_delay_ns = std.math.maxInt(u64) });
    defer rec.deinit();
    try rec.recordBoundary(header(1), .{ .what = .camera_change, .body = "x" });
    try std.testing.expect(rec.pendingBytes() > 0);
    try rec.maybeCommit(0);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);

    // A time threshold commits once the caller's clock crosses it.
    var timed = try recorder_mod.Recorder.init(gpa, sink.storage(), .{ .max_bytes = std.math.maxInt(usize), .max_delay_ns = 1_000 });
    defer timed.deinit();
    timed.observe(0);
    try timed.recordIntervention(header(1), .{ .what = .rpc_mutation, .body = "" });
    try timed.maybeCommit(500);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try timed.maybeCommit(1_100);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
}

test "the input landing adapter records an intervention at the grid position" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);

    var history = try ra8.session.history.History.init(gpa, undefined, 4);
    defer history.deinit();
    history.attachRecorder(&rec);

    const grid: scheduler.State = .{ .at = .{ .branch = 2, .r = 9, .phase = .board, .o = 0, .gap = .retired } };
    var landing = ra8.session.history.Landing{ .history = &history, .grid = &grid };
    const observer = landing.observer();
    observer.notify(observer.context, .{ .tap = .{ .x = 0x1234, .y = 0x5678 } }, 1_000);
    observer.notify(observer.context, .{ .button = .{ .down = true, .button_id = .sw2 } }, 2_000);
    try std.testing.expectEqual(@as(?anyerror, null), landing.failed);
    try rec.commit(1);

    // Two intervention frames in order: the tap at the grid position with
    // the tap's own bytes, then the button press.
    var index: usize = 0;
    var cursor: usize = 0;
    var positions: [2]record.Position = undefined;
    var whats: [2]record.Intervention.What = undefined;
    var bodies: [2]?[]const u8 = .{ null, null };
    while (cursor < sink.bytes.items.len) {
        const hit = try format.decode(sink.bytes.items[cursor..]);
        try std.testing.expectEqual(@backingInt(record.Kind.intervention), hit.frame.kind);
        const intervention = try record.decodeIntervention(hit.frame.payload);
        positions[index] = intervention.header.position;
        whats[index] = intervention.intervention.what;
        bodies[index] = intervention.intervention.body;
        cursor += hit.consumed;
        index += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), index);
    try std.testing.expect(std.meta.eql(positions[0], grid.at));
    try std.testing.expectEqual(record.Intervention.What.tap, whats[0]);
    try std.testing.expectEqualStrings(&.{ 1, 0x34, 0x12, 0x78, 0x56 }, bodies[0].?);
    try std.testing.expectEqual(record.Intervention.What.button, whats[1]);
    try std.testing.expectEqualStrings(&.{ 4, 1, 1 }, bodies[1].?);
}
