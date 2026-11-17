//! Names refer to the chip model's existing exact addresses/constants.
const std = @import("std");

const names = @import("ra8").session.annotation_names;

test "architectural registers and reset key have exact names" {
    try std.testing.expectEqualStrings("SCB.aircr", names.find(0xE000_ED0C).?);
    try std.testing.expectEqualStrings("SysTick.rvr", names.find(0xE000_E014).?);
    try std.testing.expectEqualStrings("SCB.VECTKEY", names.find(0x5FA).?);
    try std.testing.expect(names.find(0xE000_ED0D) == null);
    try std.testing.expect(names.find(0x1234) == null);
}
