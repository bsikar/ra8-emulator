//! Covers src/session/decomp/dataflow_plan.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;

test "SpillCache forwards exact and masked constant slots and invalidates overlaps" {
    var spills: decomp.dataflow_plan.SpillCache = .{};
    spills.put(-10, 2, .{ .constant = 0x1234_ABCD });
    const hit = spills.get(-10, 2, false) orelse return error.MissingSpill;
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0xABCD }, hit);

    const signed_hit = spills.get(-10, 2, true) orelse return error.MissingSigned;
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0xFFFF_ABCD }, signed_hit);

    // Overlapping word store at -12..(-8) invalidates [-10..(-8))
    spills.put(-12, 4, .{ .constant = 0x42 });
    try std.testing.expect(spills.get(-10, 2, false) == null);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0x42 }, spills.get(-12, 4, false).?);

    spills.clear();
    try std.testing.expect(spills.get(-12, 4, false) == null);
}
