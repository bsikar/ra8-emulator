//! Covers src/core/cpu/lockstep/oracle.zig.
const std = @import("std");
const ra8 = @import("ra8");
const snapshot = ra8.core.cpu.lockstep.snapshot;
const oracle = ra8.core.cpu.lockstep.oracle;
const Pair = @import("pair.zig").Pair;

test "a loaded snapshot reads back from Unicorn unchanged" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xBF });
    defer pair.close();
    const want = snapshot.Snapshot.fromRegs(&pair.cpu.regs);
    const got = try oracle.read(pair.theirs);
    try std.testing.expectEqualSlices(u32, &want.values, &got.values);
}

test "a register Unicorn holds is read under its own name" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xBF });
    defer pair.close();
    try pair.theirs.setRegister(.r5, 0x5555_AAAA);
    const got = try oracle.read(pair.theirs);
    try std.testing.expectEqual(@as(?u32, 0x5555_AAAA), got.get(.r5));
}
