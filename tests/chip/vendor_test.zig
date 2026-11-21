//! Covers src/chip/vendor.zig: vendor namespaces re-exported under ra8_chip.
const std = @import("std");
const ra8 = @import("ra8");

const vendor = ra8.chip.vendor;

test "chip.vendor exports Renesas namespace" {
    try std.testing.expectEqualStrings("ra4t1", vendor.renesas.ra4t1.machine.name);
    try std.testing.expectEqualStrings("ra8d2", vendor.renesas.ra8d2.machine.name);
    try std.testing.expectEqualStrings("ra8e1", vendor.renesas.ra8e1.machine.name);
    try std.testing.expectEqualStrings("ra8p1", vendor.renesas.ra8p1.machine.name);
}
