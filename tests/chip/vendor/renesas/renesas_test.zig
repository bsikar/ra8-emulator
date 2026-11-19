//! Covers src/chip/vendor/renesas/renesas.zig: Renesas MCU machine exports.
const std = @import("std");
const ra8 = @import("ra8");

const catalog = ra8.chip.core.machine.catalog;
const renesas = ra8.chip.vendor.renesas;

test "vendor.renesas machines match catalog re-exports" {
    try std.testing.expectEqualStrings(catalog.ra8d2.name, renesas.ra8d2.machine.name);
    try std.testing.expectEqualStrings(catalog.ra8d2.label, renesas.ra8d2.machine.label);
    try std.testing.expectEqual(catalog.ra8d2.part, renesas.ra8d2.machine.part);
    try std.testing.expectEqual(catalog.ra8d2.memory, renesas.ra8d2.machine.memory);

    try std.testing.expectEqualStrings(catalog.ra8p1.name, renesas.ra8p1.machine.name);
    try std.testing.expectEqualStrings(catalog.ra8p1.label, renesas.ra8p1.machine.label);
    try std.testing.expectEqual(catalog.ra8p1.part, renesas.ra8p1.machine.part);
    try std.testing.expectEqual(catalog.ra8p1.memory, renesas.ra8p1.machine.memory);
}
