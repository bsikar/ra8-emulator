//! The crash-after-each-write acceptance (RA8EMU-1196, slice 16): a crash
//! can stop a recorded log after any byte, so every prefix of a committed
//! segment must reopen into the same facts the recorder proved at the
//! whole length: whole frames decode in order, the torn tail stops at a
//! frame boundary, and a whole frame that lies about its bytes refuses.
//! The prefixes are real files behind a real bind, never a fake store.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;
const recorder_mod = ra8.session.history_recorder;
const record = ra8.session.history_record;
const replay_mod = ra8.session.history_replay;
const scheduler = ra8.chip.core.scheduler;
const bind_mod = ra8.rpc.history_bind;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn header(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

/// The record kinds one walk decoded, in log order, as small tags.
const Tags = struct {
    gpa: std.mem.Allocator,
    tags: std.ArrayList(u8) = .empty,
    boundaries: usize = 0,

    fn see(self: *Tags, entry: replay_mod.Entry) anyerror!void {
        const tag: u8 = switch (entry) {
            .root => 0,
            .branch => 1,
            .checkpoint => 2,
            .intervention => 3,
            .boundary => 4,
            .checkpoint_picture => 5,
        };
        try self.tags.append(self.gpa, tag);
        if (entry == .boundary) self.boundaries += 1;
    }

    fn deinit(self: *Tags) void {
        self.tags.deinit(self.gpa);
    }
};

fn drive(gpa: std.mem.Allocator, bind: *bind_mod.Bind) !void {
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.objects = bind.objects;
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "first" });
    try rec.recordBoundary(header(2), .{ .what = .c6_bytes, .body = "second" });
    try rec.checkpoint(header(3), 5, "checkpoint-state");
    try rec.recordBoundary(header(4), .{ .what = .c6_bytes, .body = "third" });
    try rec.commit(1);
}

test "every crash prefix of a recorded log reopens to the same record facts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The recorded run: three boundaries and a checkpoint, real files.
    var temp_a = std.testing.tmpDir(.{ .iterate = true });
    defer temp_a.cleanup();
    const root_a = try temp_a.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_a);
    var bind_a = try bind_mod.Bind.open(gpa, io, root_a, .{});
    defer _ = bind_a.close() catch {};
    try drive(gpa, bind_a);
    const store_a = history.storage.Store.from(&bind_a.session);
    const full = try history.readback.read(store_a, .log, "events-0", gpa);
    defer gpa.free(full);

    var whole: Tags = .{ .gpa = gpa };
    defer whole.deinit();
    const full_recovery = try replay_mod.replay(full, &whole, Tags.see);
    try std.testing.expect(!full_recovery.torn);
    try std.testing.expectEqual(full.len, full_recovery.complete_end);
    try std.testing.expectEqual(@as(usize, 3), whole.boundaries);
    try std.testing.expect(full_recovery.frames >= 4);

    // One fresh root carries every prefix: the file is rewritten to the
    // crash length, then walked back.
    var temp_b = std.testing.tmpDir(.{ .iterate = true });
    defer temp_b.cleanup();
    const root_b = try temp_b.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_b);
    var bind_b = try bind_mod.Bind.open(gpa, io, root_b, .{});
    defer _ = bind_b.close() catch {};
    const store_b = history.storage.Store.from(&bind_b.session);
    const file = try store_b.vtable.open(store_b.context, .log, "events-0", .update);
    defer file.vtable.close(file.context);

    var previous: usize = 0;
    var saw_torn = false;
    for (0..full.len + 1) |len| {
        try file.vtable.truncate(file.context, 0);
        if (len > 0) try file.vtable.write(file.context, 0, full[0..len]);
        const bytes = try history.readback.read(store_b, .log, "events-0", gpa);
        defer gpa.free(bytes);
        try std.testing.expectEqual(@as(usize, len), bytes.len);

        var walked: Tags = .{ .gpa = gpa };
        defer walked.deinit();
        const recovery = try replay_mod.replay(bytes, &walked, Tags.see);
        try std.testing.expect(recovery.complete_end <= len);
        if (recovery.torn) {
            saw_torn = true;
            try std.testing.expect(recovery.complete_end < len);
        } else {
            try std.testing.expectEqual(@as(usize, len), recovery.complete_end);
        }
        try std.testing.expect(recovery.frames <= full_recovery.frames);
        try std.testing.expect(recovery.frames >= previous);
        try std.testing.expectEqualSlices(u8, whole.tags.items[0..recovery.frames], walked.tags.items);
        previous = recovery.frames;
    }
    try std.testing.expect(saw_torn);
    try std.testing.expectEqual(@as(usize, full_recovery.frames), previous);
    // The full length walked back to the run's own facts.
    try file.vtable.truncate(file.context, 0);
    try file.vtable.write(file.context, 0, full);
    const bytes = try history.readback.read(store_b, .log, "events-0", gpa);
    defer gpa.free(bytes);
    var final: Tags = .{ .gpa = gpa };
    defer final.deinit();
    const final_recovery = try replay_mod.replay(bytes, &final, Tags.see);
    try std.testing.expect(!final_recovery.torn);
    try std.testing.expectEqual(full_recovery.frames, final_recovery.frames);
    try std.testing.expectEqual(@as(usize, 3), final.boundaries);
}

test "a whole frame whose bytes no longer match its CRC refuses the reopen" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var bind = try bind_mod.Bind.open(gpa, io, root, .{});
    defer _ = bind.close() catch {};
    try drive(gpa, bind);
    const store = history.storage.Store.from(&bind.session);
    const full = try history.readback.read(store, .log, "events-0", gpa);
    defer gpa.free(full);
    try std.testing.expect(full.len > 8);

    // The last byte sits inside the final frame's CRC trailer (the frame
    // is [u32 len][u16 kind][u32 crc32c][payload], CRC last), so the
    // frame is whole but its bytes no longer match.
    const corrupt = try gpa.dupe(u8, full);
    defer gpa.free(corrupt);
    corrupt[corrupt.len - 1] ^= 0xff;
    var walked: Tags = .{ .gpa = gpa };
    defer walked.deinit();
    _ = replay_mod.replay(corrupt, &walked, Tags.see) catch return;
    return error.CorruptRecordAccepted;
}
