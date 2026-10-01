//! Covers src/core/cpu/lockstep/snapshot.zig.
const std = @import("std");
const ra8 = @import("ra8");
const snapshot = ra8.core.cpu.lockstep.snapshot;
const regs = ra8.core.cpu.regs;

test "a snapshot reads every compared register off the Zig core's file" {
    var file: regs.Regs = .{};
    file.low[3] = 0x1234;
    file.msp = 0x2000_0100;
    file.psp = 0x2000_0200;
    file.xpsr = regs.xpsr_bits.thumb;
    const shot = snapshot.Snapshot.fromRegs(&file);
    try std.testing.expectEqual(@as(?u32, 0x1234), shot.get(.r3));
    try std.testing.expectEqual(@as(?u32, 0x2000_0100), shot.get(.msp));
    try std.testing.expectEqual(@as(?u32, 0x2000_0200), shot.get(.psp));
    try std.testing.expectEqual(@as(?u32, regs.xpsr_bits.thumb), shot.get(.xpsr));
}

test "SP is not compared on its own, only through the banked pointers" {
    try std.testing.expectEqual(@as(?usize, null), snapshot.Snapshot.index(.sp));
    try std.testing.expect(snapshot.Snapshot.index(.msp) != null);
    try std.testing.expect(snapshot.Snapshot.index(.psp) != null);
}

test "every register but SP is compared exactly once" {
    for (std.enums.values(regs.Name)) |name| {
        var seen: usize = 0;
        for (snapshot.compared) |candidate| {
            if (candidate == name) seen += 1;
        }
        const want: usize = if (name == .sp) 0 else 1;
        try std.testing.expectEqual(want, seen);
    }
}
