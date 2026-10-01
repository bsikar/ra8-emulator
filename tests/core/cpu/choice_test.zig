//! Covers src/core/cpu/choice.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Choice = ra8.core.cpu.choice.Choice;

test "--cpu takes the three names and nothing else" {
    try std.testing.expectEqual(Choice.unicorn, Choice.parse("unicorn").?);
    try std.testing.expectEqual(Choice.zig, Choice.parse("zig").?);
    try std.testing.expectEqual(Choice.lockstep, Choice.parse("lockstep").?);
    try std.testing.expect(Choice.parse("Zig") == null);
    try std.testing.expect(Choice.parse("") == null);
}
