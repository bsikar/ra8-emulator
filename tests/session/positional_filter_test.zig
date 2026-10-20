//! The positional filter (RA8EMU-1196): a walk over a committed log
//! selects the records at and after a scheduler position by their
//! headers alone, so a reader can seek to a checkpoint's round without
//! a new record kind.

const std = @import("std");
const ra8 = @import("ra8");
const record_mod = ra8.session.history_record;
const replay_mod = ra8.session.history_replay;
const fakes = @import("history_fakes.zig");

const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";

/// Every non-root entry one walk saw, in log order, with the header
/// fields the filter reads.
const Walk = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Step) = .empty,

    const Step = struct { checkpoint: bool, pos: record_mod.Position, seq: u32 };

    fn see(self: *Walk, entry: replay_mod.Entry) anyerror!void {
        switch (entry) {
            .root => {},
            inline else => |hit| try self.entries.append(self.gpa, .{
                .checkpoint = entry == .checkpoint,
                .pos = hit.header.position,
                .seq = hit.header.seq,
            }),
        }
    }

    fn deinit(self: *Walk) void {
        self.entries.deinit(self.gpa);
    }
};

test "a committed log's walk filters its records by position" {
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

    _ = try session.run(.cpu0, .run);

    var walk: Walk = .{ .gpa = gpa };
    defer walk.deinit();
    _ = try replay_mod.replay(sink.bytes.items, &walk, Walk.see);
    try std.testing.expect(walk.entries.items.len > 0);

    // The headers order the log: one branch's records never go back a
    // position, and events sharing one position keep their source
    // sequence order.
    for (walk.entries.items, 0..) |one, i| {
        if (i > 0) {
            const before = walk.entries.items[i - 1];
            try std.testing.expectEqual(before.pos.branch, one.pos.branch);
            const ordered = record_mod.Position.order(before.pos, one.pos);
            try std.testing.expect(ordered == .lt or ordered == .eq);
            if (ordered == .eq) try std.testing.expect(one.seq > before.seq);
        }
    }

    // The checkpoints climb the rounds the same way.
    var checkpoints: std.ArrayList(usize) = .empty;
    defer checkpoints.deinit(gpa);
    for (walk.entries.items, 0..) |one, i| {
        if (one.checkpoint) try checkpoints.append(gpa, i);
    }
    try std.testing.expect(checkpoints.items.len >= 2);
    for (checkpoints.items[1..], 0..) |one, i| {
        try std.testing.expect(
            walk.entries.items[one].pos.r > walk.entries.items[checkpoints.items[i]].pos.r,
        );
    }

    // The filter is a pure predicate on the headers: the records at and
    // after the second checkpoint's round are exactly the walk's tail
    // there, and they open with that checkpoint.
    const seek_r = walk.entries.items[checkpoints.items[1]].pos.r;
    var first_at = walk.entries.items.len;
    for (walk.entries.items, 0..) |one, i| {
        if (one.pos.r >= seek_r) {
            first_at = i;
            break;
        }
    }
    try std.testing.expect(first_at < walk.entries.items.len);
    for (walk.entries.items[first_at..]) |one| {
        try std.testing.expect(one.pos.r >= seek_r);
    }
    try std.testing.expect(walk.entries.items[first_at].checkpoint);
}
