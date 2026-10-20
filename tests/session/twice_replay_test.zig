//! The twice-replay comparison (RA8EMU-1196): a checkpoint's object
//! restores the run, and replaying forward from it lands the same save
//! stream the recorded run kept, so a persisted history's checkpoints
//! agree with what a fresh replay from any of them produces.
const std = @import("std");
const ra8 = @import("ra8");
const recorder_mod = ra8.session.history_recorder;
const replay_mod = ra8.session.history_replay;

const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";

/// The in-memory log storage: the recorder's committed frames land in
/// one buffer, and the walk reads it back.
const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn append(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.gpa, data);
    }

    fn flush(context: *anyopaque) anyerror!void {
        _ = context;
    }

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
    }

    fn storage(self: *Sink) recorder_mod.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }

    fn deinit(self: *Sink) void {
        self.bytes.deinit(self.gpa);
    }
};

/// The in-memory object space: names keep the bytes they were put with.
const Objects = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Named) = .empty,

    const Named = struct { name: [32]u8, bytes: []u8 };

    fn put(context: *anyopaque, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *Objects = @ptrCast(@alignCast(context));
        var slot: Named = .{ .name = undefined, .bytes = try self.gpa.dupe(u8, bytes) };
        @memcpy(&slot.name, name);
        try self.items.append(self.gpa, slot);
    }

    fn sync(context: *anyopaque) anyerror!void {
        _ = context;
    }

    fn objects(self: *Objects) recorder_mod.Objects {
        return .{ .context = self, .put = put, .sync = sync };
    }

    /// The bytes one name holds, or null when nothing was put under it.
    fn get(self: *const Objects, name: []const u8) ?[]const u8 {
        for (self.items.items) |one| {
            if (std.mem.eql(u8, &one.name, name)) return one.bytes;
        }
        return null;
    }

    fn deinit(self: *Objects) void {
        for (self.items.items) |one| self.gpa.free(one.bytes);
        self.items.deinit(self.gpa);
    }
};

/// The checkpoint records one walk collected, in log order.
const Hits = struct {
    gpa: std.mem.Allocator,
    checkpoints: std.ArrayList(Hit) = .empty,

    const Hit = struct { id: u32, object: [16]u8, round: u64 };

    fn see(self: *Hits, entry: replay_mod.Entry) anyerror!void {
        switch (entry) {
            .checkpoint => |hit| try self.checkpoints.append(self.gpa, .{
                .id = hit.checkpoint.id,
                .object = hit.checkpoint.object,
                .round = hit.header.position.r,
            }),
            else => {},
        }
    }

    fn deinit(self: *Hits) void {
        self.checkpoints.deinit(self.gpa);
    }
};

test "a checkpoint's object restores the run and a replay lands its next checkpoint again" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = elf_path,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    const history = opened.history();

    // The recorded run: a counted run closes rounds at the stretch
    // boundaries, and every eighth closed round checkpoints the whole
    // machine's save stream.
    _ = try session.run(.cpu0, .run);

    var first: Hits = .{ .gpa = gpa };
    defer first.deinit();
    _ = try replay_mod.replay(sink.bytes.items, &first, Hits.see);
    for (first.checkpoints.items) |one| {
        std.debug.print("recorded: id={d} round={d} digest={x}\n", .{ one.id, one.round, one.object });
    }
    try std.testing.expect(first.checkpoints.items.len >= 2);

    // Restore the run to the first checkpoint's state...
    const digest: [16]u8 = first.checkpoints.items[0].object;
    var name: [32]u8 = undefined;
    for (digest, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte});
    }
    const saved = objects.get(&name) orelse return error.MissingObject;
    std.debug.print("restoring: bytes={d}\n", .{saved.len});
    try dumpDiff(std.testing.io, "/tmp/checkpoint0.bin", saved);
    history.restoreBytes(saved) catch |e| {
        std.debug.print("restoreBytes failed: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("restored ok\n", .{});

    // ...and replay the run forward from it: the restored machine is a
    // started machine, so the replay continues it.
    _ = session.run(.cpu0, .cont) catch |e| {
        std.debug.print("replay run failed: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("replay run ok\n", .{});

    // The replayed run's checkpoints carry the save-stream digests the
    // recorded run kept for the same rounds: the next checkpoint's
    // object agrees with the one after the restored point.
    var again: Hits = .{ .gpa = gpa };
    defer again.deinit();
    _ = try replay_mod.replay(sink.bytes.items, &again, Hits.see);
    try std.testing.expect(again.checkpoints.items.len > first.checkpoints.items.len);

    const fresh_start = first.checkpoints.items.len;
    std.debug.print("after replay: recorded={d} total={d} fresh={d}\n", .{ first.checkpoints.items.len, again.checkpoints.items.len, again.checkpoints.items.len - fresh_start });
    for (again.checkpoints.items[fresh_start..]) |one| {
        std.debug.print("fresh: id={d} round={d} digest={x}\n", .{ one.id, one.round, one.object });
    }
    const comparable = @min(again.checkpoints.items.len - fresh_start, first.checkpoints.items.len - 1);
    try std.testing.expect(comparable >= 1);
    for (0..comparable) |i| {
        const recorded: [16]u8 = first.checkpoints.items[i + 1].object;
        const replayed: [16]u8 = again.checkpoints.items[fresh_start + i].object;
        std.debug.print("cmp {d}: recorded {x} replayed {x}\n", .{ i + 1, recorded, replayed });
        if (!std.mem.eql(u8, &recorded, &replayed)) {
            var rn: [32]u8 = undefined;
            var fn_: [32]u8 = undefined;
            for (recorded, 0..) |byte, j| _ = try std.fmt.bufPrint(rn[j * 2 ..][0..2], "{x:0>2}", .{byte});
            for (replayed, 0..) |byte, j| _ = try std.fmt.bufPrint(fn_[j * 2 ..][0..2], "{x:0>2}", .{byte});
            const rb = objects.get(&rn) orelse return error.MissingObject;
            const fb = objects.get(&fn_) orelse return error.MissingObject;
            std.debug.print("cmp {d}: bytes recorded={d} fresh={d}\n", .{ i + 1, rb.len, fb.len });
            try dumpDiff(std.testing.io, "/tmp/recorded_r2.bin", rb);
            try dumpDiff(std.testing.io, "/tmp/fresh_r2.bin", fb);
        }
        try std.testing.expectEqual(recorded, replayed);
    }
}

fn dumpDiff(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
