//! Covers src/chip/core/part/cores.zig: RA8D2/RA8P1 core descriptors match the
//! cited datasheet capabilities (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const cores = ra8.chip.core.part.cores;
const cpuid = ra8.chip.periph.cpuid;

test "RA8 CPU0 and CPU1 descriptors match existing part constants" {
    try std.testing.expectEqual(cpuid.cpu0, cores.cpu0.cpuid);
    try std.testing.expectEqual(cpuid.cpu1, cores.cpu1.cpuid);
    try std.testing.expectEqual(ra8.chip.core.part.cpu0_profile, cores.cpu0.profile);
    try std.testing.expectEqual(ra8.chip.core.part.cpu1_profile, cores.cpu1.profile);
    try std.testing.expectEqual(ra8.chip.core.part.cpu0_systicks, cores.cpu0.systicks);
    try std.testing.expectEqual(ra8.chip.core.part.cpu1_systicks, cores.cpu1.systicks);
}
