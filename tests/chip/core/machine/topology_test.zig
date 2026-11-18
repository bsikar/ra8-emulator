//! Covers src/chip/core/machine/topology.zig: slot lookup and absent-core
//! refusal (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const core = ra8.chip.core.machine.core;
const topology = ra8.chip.core.machine.topology;

test "a single-core topology exposes slot 0 and refuses slot 1" {
    const m33 = core.cortexM33(.{ .security = false, .fpu = .single, .systicks = 1 });
    const single: topology.Topology = .{ .primary = m33 };
    try std.testing.expectEqual(@as(u2, 1), single.count());
    try std.testing.expect(single.has(.cpu0));
    try std.testing.expect(!single.has(.cpu1));
    try std.testing.expectEqual(m33.cpuid, (try single.require(.cpu0)).cpuid);
    try std.testing.expectEqual(@as(?core.Core, null), single.at(.cpu1));
    try std.testing.expectError(error.AbsentCore, single.require(.cpu1));
}

test "a dual-core topology answers both slots independently" {
    const m85 = core.cortexM85(.{ .security = true, .fpu = .double, .systicks = 2 });
    const m33 = core.cortexM33(.{ .security = true, .fpu = .single, .systicks = 2 });
    const dual: topology.Topology = .{ .primary = m85, .second = m33 };
    try std.testing.expectEqual(@as(u2, 2), dual.count());
    try std.testing.expect(dual.has(.cpu0));
    try std.testing.expect(dual.has(.cpu1));
    try std.testing.expectEqual(m85.cpuid, (try dual.require(.cpu0)).cpuid);
    try std.testing.expectEqual(m33.cpuid, (try dual.require(.cpu1)).cpuid);
}
