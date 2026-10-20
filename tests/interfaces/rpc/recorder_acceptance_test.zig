//! The slice's acceptance scenarios on the real host store behind the
//! RPC bind: a crash's torn tail recovers to the last whole frame, a
//! whole frame that fails its CRC refuses the reopen, and a closed
//! session leaves the root's catalog with nothing of it left.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;
const recorder_mod = ra8.session.history_recorder;
const record = ra8.session.history_record;
const format = ra8.session.history_format;
const scheduler = ra8.chip.core.scheduler;

const bind_mod = ra8.rpc.history_bind;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn header(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

/// The storage a reopen drive hands recoverSegment: it only ever
/// records the shortening the recovery asks for.
const Trim = struct {
    cuts: std.ArrayList(u64) = .empty,

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Trim = @ptrCast(@alignCast(context));
        try self.cuts.append(std.testing.allocator, len);
    }

    fn storage(self: *Trim) recorder_mod.Storage {
        return .{ .context = self, .append = undefined, .flush = undefined, .truncate = truncate };
    }
};

test "acceptance: a torn tail recovers to the last whole frame on the real store" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root);
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer {
        rec.deinit();
        _ = bind.close() catch {};
    }
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.recordIntervention(header(2), .{ .what = .tap, .body = "xy" });
    try rec.commit(1);
    try rec.recordBoundary(header(3), .{ .what = .c6_bytes, .body = "tail" });
    try rec.commit(2);

    const store = history.storage.Store.from(&bind.session);
    const log = try store.vtable.open(store.context, .log, "events-0", .read);
    const len = try log.vtable.length(log.context);
    const bytes = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(bytes);
    _ = try log.vtable.read(log.context, 0, bytes);
    log.vtable.close(log.context);
    try std.testing.expect(len > 3);

    // A crash that landed part of the third frame: the reopen keeps
    // the two whole frames and cuts the torn tail at the torn
    // frame's start, which the decode walk places.
    var cursor: usize = 0;
    var ends: [2]u64 = undefined;
    for (&ends) |*end| {
        const hit = try format.decode(bytes[cursor..]);
        cursor += hit.consumed;
        end.* = cursor;
    }
    var trim: Trim = .{};
    defer trim.cuts.deinit(gpa);
    const recovery = try recorder_mod.recoverSegment(bytes[0 .. len - 3], trim.storage());
    try std.testing.expect(recovery.torn);
    try std.testing.expectEqual(@as(usize, 2), recovery.frames);
    try std.testing.expectEqual(ends[1], recovery.complete_end);
    try std.testing.expectEqual(@as(usize, 1), trim.cuts.items.len);
    try std.testing.expectEqual(ends[1], trim.cuts.items[0]);
}

test "acceptance: a whole frame that fails its crc refuses the reopen" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root);
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.recordIntervention(header(2), .{ .what = .tap, .body = "xy" });
    try rec.commit(1);

    // One flipped byte inside the first frame's payload: a whole
    // frame whose CRC no longer matches refuses the reopen rather
    // than being cut away.
    const store = history.storage.Store.from(&bind.session);
    const log = try store.vtable.open(store.context, .log, "events-0", .read);
    const len = try log.vtable.length(log.context);
    const bytes = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(bytes);
    _ = try log.vtable.read(log.context, 0, bytes);
    log.vtable.close(log.context);
    const back = try store.vtable.open(store.context, .log, "events-0", .update);
    bytes[12] ^= 0xFF;
    try back.vtable.write(back.context, 12, @as(*const [1]u8, &bytes[12]));
    back.vtable.close(back.context);

    var trim: Trim = .{};
    defer trim.cuts.deinit(gpa);
    try std.testing.expectError(error.BadCrc, recorder_mod.recoverSegment(bytes, trim.storage()));
    try std.testing.expectEqual(@as(usize, 0), trim.cuts.items.len);
    try std.testing.expectEqual(history.session.Outcome.deleted, try bind.close());
}

test "acceptance: a closed session leaves the root's catalog empty" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var base_root = try history.base.Base.open(gpa, std.testing.io, root, .cache);
    defer base_root.close();
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root);
    try bind.storage.append(bind.storage.context, "recorded bytes");
    try bind.objects.put(bind.objects.context, "0123456789abcdef", "object bytes");
    var entries = try history.catalog.Iterator.init(&base_root);
    const entry = (try entries.next()).?;
    const held = try history.catalog.du(&base_root, entry.name);
    try std.testing.expect(held > 0);
    try std.testing.expectEqual(history.session.Outcome.deleted, try bind.close());
    var after = try history.catalog.Iterator.init(&base_root);
    try std.testing.expect((try after.next()) == null);
}
