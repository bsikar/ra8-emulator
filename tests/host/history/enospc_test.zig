//! The storage-failure acceptance (RA8EMU-1196, slice 16): a full device
//! can stop a commit's append in part, so a failed commit must leave the
//! storage exactly at the committed length and its batch staged, and the
//! retry must land the whole batch whole. Real files behind a real bind,
//! never a fake store.
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
    }

    fn deinit(self: *Tags) void {
        self.tags.deinit(self.gpa);
    }
};

/// The storage the recorder writes through: the bind's real file ops,
/// with an injection point a test arms to stop an append once the bytes
/// written through it cross a total, in part or whole.
const Inject = struct {
    inner: recorder_mod.Storage,
    /// Bytes that reached the inner storage through this wrapper.
    written: usize = 0,
    /// When armed, an append that would cross this total stops here: the
    /// room that remains goes out in part, then the device reports full.
    fail_at: ?usize = null,

    fn storage(self: *Inject) recorder_mod.Storage {
        return .{ .context = self, .append = &append, .flush = &flush, .truncate = &truncate };
    }

    fn append(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Inject = @ptrCast(@alignCast(context));
        const room = if (self.fail_at) |at| at -| self.written else bytes.len;
        if (room >= bytes.len) {
            try self.inner.append(self.inner.context, bytes);
            self.written += bytes.len;
            return;
        }
        if (room > 0) try self.inner.append(self.inner.context, bytes[0..room]);
        self.written += room;
        return error.NoSpaceLeft;
    }

    fn flush(context: *anyopaque) anyerror!void {
        const self: *Inject = @ptrCast(@alignCast(context));
        try self.inner.flush(self.inner.context);
    }

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Inject = @ptrCast(@alignCast(context));
        try self.inner.truncate(self.inner.context, len);
    }
};

/// Stages the whole run on `rec`, writing through the storage the
/// caller hands over: the first commit lands, the rest of the run stays
/// staged for the test's commits.
fn stage(
    gpa: std.mem.Allocator,
    bind: *bind_mod.Bind,
    into: recorder_mod.Storage,
    rec: *recorder_mod.Recorder,
) !void {
    rec.* = try recorder_mod.Recorder.init(gpa, into, .{});
    rec.objects = bind.objects;
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "first" });
    try rec.commit(1);
    try rec.recordBoundary(header(2), .{ .what = .c6_bytes, .body = "second" });
    try rec.checkpoint(header(3), 5, "checkpoint-state");
    try rec.recordBoundary(header(4), .{ .what = .c6_bytes, .body = "third" });
}

/// One failing commit at `room` bytes of the staged batch, then the
/// retry with the device whole again, all on one root.
fn failThenRetry(gpa: std.mem.Allocator, room: usize) !void {
    // The reference run, whole on its own root, is the facts the retry
    // must reproduce byte for byte.
    var temp_ref = std.testing.tmpDir(.{ .iterate = true });
    defer temp_ref.cleanup();
    const io = std.testing.io;
    const root_ref = try temp_ref.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_ref);
    var bind_ref = try bind_mod.Bind.open(gpa, io, root_ref, .{});
    defer _ = bind_ref.close() catch {};
    var rec_ref: recorder_mod.Recorder = undefined;
    try stage(gpa, bind_ref, bind_ref.storage, &rec_ref);
    defer rec_ref.deinit();
    // The reference lands the whole batch, so `whole` is the run whole.
    try rec_ref.commit(2);
    const store_ref = history.storage.Store.from(&bind_ref.session);
    const whole = try history.readback.read(store_ref, .log, "events-0", gpa);
    defer gpa.free(whole);

    var whole_tags: Tags = .{ .gpa = gpa };
    defer whole_tags.deinit();
    const whole_recovery = try replay_mod.replay(whole, &whole_tags, Tags.see);
    try std.testing.expect(!whole_recovery.torn);

    // The run under injection.
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var bind = try bind_mod.Bind.open(gpa, io, root, .{});
    defer _ = bind.close() catch {};
    const store = history.storage.Store.from(&bind.session);
    var inject: Inject = .{ .inner = bind.storage };
    var rec: recorder_mod.Recorder = undefined;
    try stage(gpa, bind, inject.storage(), &rec);
    defer rec.deinit();

    // The first commit landed whole; the rest of the run is staged.
    const first_end = try bind.logLength();
    try std.testing.expectEqual(@as(u64, inject.written), first_end);
    try std.testing.expectEqual(first_end, rec.committed_bytes);
    const batch = rec.pendingBytes();
    try std.testing.expect(batch > 0);

    // The device stops the commit's append `room` bytes in.
    inject.fail_at = inject.written + room;
    try std.testing.expectError(error.NoSpaceLeft, rec.commit(2));

    // The failed commit left the storage at the committed length and the
    // batch staged, so nothing is duplicated and nothing is lost.
    try std.testing.expectEqual(rec.committed_bytes, try bind.logLength());
    try std.testing.expectEqual(batch, rec.pendingBytes());

    // What did land before the failure walked back to the committed
    // frames and nothing more.
    const kept = try history.readback.read(store, .log, "events-0", gpa);
    defer gpa.free(kept);
    var kept_tags: Tags = .{ .gpa = gpa };
    defer kept_tags.deinit();
    const kept_recovery = try replay_mod.replay(kept, &kept_tags, Tags.see);
    try std.testing.expect(!kept_recovery.torn);
    try std.testing.expectEqual(kept.len, kept_recovery.complete_end);

    // The retry, with the device whole again, lands the whole batch.
    inject.fail_at = null;
    try rec.commit(3);
    try std.testing.expectEqual(rec.committed_bytes, try bind.logLength());

    const final = try history.readback.read(store, .log, "events-0", gpa);
    defer gpa.free(final);
    try std.testing.expectEqualSlices(u8, whole, final);
    var final_tags: Tags = .{ .gpa = gpa };
    defer final_tags.deinit();
    const final_recovery = try replay_mod.replay(final, &final_tags, Tags.see);
    try std.testing.expect(!final_recovery.torn);
    try std.testing.expectEqual(whole_recovery.frames, final_recovery.frames);
    try std.testing.expectEqualSlices(u8, whole_tags.tags.items, final_tags.tags.items);
}

test "a stopped append mid-batch leaves the storage at the committed length and the retry lands the whole batch" {
    const gpa = std.testing.allocator;
    try failThenRetry(gpa, 5);
}

test "a wholly refused append leaves the storage untouched and the retry lands the whole batch" {
    const gpa = std.testing.allocator;
    try failThenRetry(gpa, 0);
}
