//! Covers src/core/cpu/lockstep/diff.zig.
const std = @import("std");
const ra8 = @import("ra8");
const diff = ra8.core.cpu.lockstep.diff;
const snapshot = ra8.core.cpu.lockstep.snapshot;
const regs = ra8.core.cpu.regs;

fn shotWith(edits: []const struct { regs.Name, u32 }) snapshot.Snapshot {
    var file: regs.Regs = .{};
    for (edits) |edit| file.write(edit[0], edit[1]);
    return snapshot.Snapshot.fromRegs(&file);
}

test "agreeing states have no mismatch" {
    const a = shotWith(&.{.{ .r0, 7 }});
    try std.testing.expectEqual(@as(?diff.Mismatch, null), diff.first(a, a));
    var into: [4]diff.Mismatch = undefined;
    try std.testing.expectEqual(@as(usize, 0), diff.all(a, a, &into));
}

test "the first mismatch is the earliest register in compared order" {
    const ours = shotWith(&.{ .{ .r2, 1 }, .{ .pc, 0x100 } });
    const oracle = shotWith(&.{ .{ .r2, 2 }, .{ .pc, 0x104 } });
    const found = diff.first(ours, oracle).?;
    try std.testing.expectEqual(regs.Name.r2, found.name);
    try std.testing.expectEqual(@as(u32, 1), found.ours);
    try std.testing.expectEqual(@as(u32, 2), found.oracle);
}

test "all counts every mismatch even past the buffer" {
    const ours = shotWith(&.{ .{ .r0, 1 }, .{ .r1, 1 }, .{ .r2, 1 } });
    const oracle = shotWith(&.{});
    var into: [2]diff.Mismatch = undefined;
    try std.testing.expectEqual(@as(usize, 3), diff.all(ours, oracle, &into));
    try std.testing.expectEqual(regs.Name.r1, into[1].name);
}

test "a mismatch prints both values by register name" {
    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const mismatch: diff.Mismatch = .{ .name = .lr, .ours = 0x10, .oracle = 0xFFFF_FFF9 };
    try mismatch.write(stream.writer());
    try std.testing.expectEqualStrings("lr: zig 0x00000010, unicorn 0xFFFFFFF9", stream.getWritten());
}
