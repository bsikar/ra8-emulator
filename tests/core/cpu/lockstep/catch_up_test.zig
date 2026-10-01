//! Covers src/core/cpu/lockstep/catch_up.zig.
const std = @import("std");
const ra8 = @import("ra8");
const catch_up = ra8.core.cpu.lockstep.catch_up;
const writes = ra8.core.cpu.lockstep.writes;
const snapshot = ra8.core.cpu.lockstep.snapshot;
const oracle = ra8.core.cpu.lockstep.oracle;
const diff = ra8.core.cpu.lockstep.diff;
const Pair = @import("pair.zig").Pair;
const entry = @import("pair.zig").entry;

test "after catching up Unicorn holds the Zig core's registers and stores" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xBF });
    defer pair.close();
    pair.cpu.regs.set(3, 0x1234_5678);
    pair.cpu.regs.pc = entry + 2;
    var store: writes.Write = .{ .address = entry + 0x100, .len = 2 };
    store.bytes[0] = 0xCA;
    store.bytes[1] = 0xFE;
    try catch_up.toZig(pair.theirs, &pair.cpu.regs, &.{store});
    const theirs = try oracle.read(pair.theirs);
    try std.testing.expect(diff.first(snapshot.Snapshot.fromRegs(&pair.cpu.regs), theirs) == null);
    var held: [2]u8 = undefined;
    try pair.theirs.read(entry + 0x100, &held);
    try std.testing.expectEqualSlices(u8, &.{ 0xCA, 0xFE }, &held);
}
