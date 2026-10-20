//! The twice-replay comparison (RA8EMU-1196): a checkpoint's object
//! restores the run, and replaying forward from it lands the same save
//! stream the recorded run kept, so a persisted history's checkpoints
//! agree with what a fresh replay from any of them produces.

const std = @import("std");
const ra8 = @import("ra8");
const replay_mod = ra8.session.history_replay;
const fakes = @import("history_fakes.zig");

const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";

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

/// The name one digest is put under in the object space.
fn objectName(digest: [16]u8) ![32]u8 {
    var name: [32]u8 = undefined;
    for (digest, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte});
    }
    return name;
}

test "a checkpoint's object restores the run and a replay lands its next checkpoint again" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
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
    // boundaries, and the recorder checkpoints the whole machine's save
    // stream on its thinning schedule.
    _ = try session.run(.cpu0, .run);

    var first: Hits = .{ .gpa = gpa };
    defer first.deinit();
    _ = try replay_mod.replay(sink.bytes.items, &first, Hits.see);
    try std.testing.expect(first.checkpoints.items.len >= 2);

    // Restore the run to the first checkpoint's state...
    const name = try objectName(first.checkpoints.items[0].object);
    const saved = objects.get(&name) orelse return error.MissingObject;
    try history.restoreBytes(saved);

    // ...and replay the run forward from it: the restored machine is a
    // started machine, so the replay continues it.
    _ = try session.run(.cpu0, .cont);

    // The replayed run's checkpoints carry the save-stream digests the
    // recorded run kept for the same rounds.
    var again: Hits = .{ .gpa = gpa };
    defer again.deinit();
    _ = try replay_mod.replay(sink.bytes.items, &again, Hits.see);
    try std.testing.expect(again.checkpoints.items.len > first.checkpoints.items.len);

    const fresh_start = first.checkpoints.items.len;
    const comparable = @min(again.checkpoints.items.len - fresh_start, first.checkpoints.items.len - 1);
    try std.testing.expect(comparable >= 1);
    for (0..comparable) |i| {
        try std.testing.expectEqual(
            first.checkpoints.items[i + 1].object,
            again.checkpoints.items[fresh_start + i].object,
        );
    }
}
