//! Covers src/chip/vendor/renesas/ra8p1.zig: Renesas RA8P1 dual-core MCU machine.
const std = @import("std");
const ra8 = @import("ra8");

const cpuid = ra8.chip.periph.cpuid;
const machine_mem = ra8.chip.core.machine.memory;
const ra8p1 = ra8.chip.vendor.renesas.ra8p1;

test "vendor.renesas.ra8p1 defines dual-core RA8P1 with NPU" {
    const m = ra8p1.machine;
    try std.testing.expectEqualStrings("ra8p1", m.name);
    try std.testing.expectEqualStrings("RA8P1", m.label);
    try std.testing.expectEqual(@as(usize, 0), m.aliases.len);
    try std.testing.expectEqual(ra8.chip.core.part.Part.ra8p1, m.part);
    try std.testing.expectEqual(&machine_mem.ra8, m.memory);
    try std.testing.expect(m.hasSecond());
    try std.testing.expect(m.hasNpu());
    try std.testing.expectEqual(cpuid.cpu0, m.primary().cpuid);
    try std.testing.expectEqual(cpuid.cpu1, m.core(.cpu1).?.cpuid);
}
