//! Covers src/chip/core/machine/catalog.zig: RA8D2 and RA8P1 machine instances
//! and unknown-name refusal (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const catalog = ra8.chip.core.machine.catalog;
const cpuid = ra8.chip.periph.cpuid;

test "ra8d2 and ra8p1 resolve by exact name and refuse unknown names" {
    try std.testing.expectEqual(&catalog.ra8d2, catalog.find("ra8d2").?);
    try std.testing.expectEqual(&catalog.ra8p1, catalog.find("ra8p1").?);
    try std.testing.expectEqual(@as(?*const ra8.chip.core.machine.Machine, null), catalog.find("RA8D2"));
    try std.testing.expectEqual(@as(?*const ra8.chip.core.machine.Machine, null), catalog.find("unknown"));
    try std.testing.expectEqual(@as(?*const ra8.chip.core.machine.Machine, null), catalog.find(""));
}

test "ra8d2 and ra8p1 carry M85 primary and M33 secondary cores" {
    for (catalog.all) |m| {
        try std.testing.expect(m.hasSecond());
        try std.testing.expectEqual(cpuid.cpu0, m.primary().cpuid);
        try std.testing.expectEqual(cpuid.cpu1, m.core(.cpu1).?.cpuid);
        try std.testing.expect(m.primary().has(.v8_1m));
        try std.testing.expect(!m.core(.cpu1).?.has(.v8_1m));
    }
    try std.testing.expect(!catalog.ra8d2.hasNpu());
    try std.testing.expect(catalog.ra8p1.hasNpu());
}
