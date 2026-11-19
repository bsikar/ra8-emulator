//! Covers src/chip/vendor/renesas/ra8d2.zig: Renesas RA8D2 dual-core MCU machine.
const std = @import("std");
const ra8 = @import("ra8");

const cpuid = ra8.chip.periph.cpuid;
const machine_mem = ra8.chip.core.machine.memory;
const ra8d2 = ra8.chip.vendor.renesas.ra8d2;

test "vendor.renesas.ra8d2 defines dual-core RA8D2 without NPU" {
    const m = ra8d2.machine;
    try std.testing.expectEqualStrings("ra8d2", m.name);
    try std.testing.expectEqualStrings("RA8D2", m.label);
    try std.testing.expectEqual(@as(usize, 0), m.aliases.len);
    try std.testing.expectEqual(ra8.chip.core.part.Part.ra8d2, m.part);
    try std.testing.expectEqual(&machine_mem.ra8, m.memory);
    try std.testing.expect(m.hasSecond());
    try std.testing.expect(!m.hasNpu());
    try std.testing.expectEqual(cpuid.cpu0, m.primary().cpuid);
    try std.testing.expectEqual(cpuid.cpu1, m.core(.cpu1).?.cpuid);
}
