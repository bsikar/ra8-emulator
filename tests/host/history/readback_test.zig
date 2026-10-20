//! The read-back of a recorded history from the real host store behind
//! the RPC bind (RA8EMU-1196): a stored file comes back whole, and a
//! committed log segment walks back into records whose checkpoint names
//! the object the recorder staged beside it.
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

test "a stored file reads back whole" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    const store = history.storage.Store.from(&bind.session);

    const written = try store.vtable.open(store.context, .objects, "aa00", .create);
    try written.vtable.write(written.context, 0, "hello");
    written.vtable.close(written.context);

    const bytes = try history.readback.read(store, .objects, "aa00", gpa);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
}

test "a committed log walks back to a checkpoint that names its object" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = bind.objects;

    const state = "checkpoint-state";
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.checkpoint(header(2), 5, state);
    try rec.commit(1);

    const store = history.storage.Store.from(&bind.session);
    const log_bytes = try history.readback.read(store, .log, "events-0", gpa);
    defer gpa.free(log_bytes);

    const Walk = struct {
        checkpoint_id: ?u32 = null,
        object: [16]u8 = undefined,
        boundaries: usize = 0,

        fn see(self: *@This(), entry: replay_mod.Entry) anyerror!void {
            switch (entry) {
                .checkpoint => |hit| {
                    self.checkpoint_id = hit.checkpoint.id;
                    self.object = hit.checkpoint.object;
                },
                .boundary => self.boundaries += 1,
                else => {},
            }
        }
    };
    var walk: Walk = .{};
    const recovery = try replay_mod.replay(log_bytes, &walk, Walk.see);
    try std.testing.expect(!recovery.torn);
    try std.testing.expectEqual(@as(usize, 1), walk.boundaries);
    try std.testing.expectEqual(@as(u32, 5), walk.checkpoint_id.?);

    // The record's object field is the digest's first 16 raw bytes; the
    // object it names sits in the object space under the lowercase hex.
    var name: [32]u8 = undefined;
    for (walk.object, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte});
    }
    const object_bytes = try history.readback.read(store, .objects, &name, gpa);
    defer gpa.free(object_bytes);
    try std.testing.expectEqualStrings(state, object_bytes);
}
