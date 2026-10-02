//! Covers src/core/cpu/lockstep/step.zig.
const std = @import("std");
const ra8 = @import("ra8");
const step = ra8.core.cpu.lockstep.step;
const pair_mod = @import("pair.zig");
const Pair = pair_mod.Pair;

test "a NOP on both backends matches under the hint class" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xBF, 0x00, 0xBF });
    defer pair.close();
    const result = try step.one(&pair.cpu, pair.theirs);
    try std.testing.expectEqualStrings("hint", result.matched);
    try std.testing.expectEqual(pair_mod.entry + 2, pair.cpu.regs.pc);
    try std.testing.expectEqualStrings("hint", (try step.one(&pair.cpu, pair.theirs)).matched);
}

test "a register the backends disagree on is reported with both values" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xBF });
    defer pair.close();
    try pair.theirs.setRegister(.r0, 1);
    const result = try step.one(&pair.cpu, pair.theirs);
    const found = result.diverged;
    try std.testing.expectEqualStrings("hint", found.class);
    try std.testing.expectEqual(ra8.core.cpu.regs.Name.r0, found.what.register.name);
    try std.testing.expectEqual(@as(u32, 0), found.what.register.ours);
    try std.testing.expectEqual(@as(u32, 1), found.what.register.oracle);
}

test "an encoding the Zig core does not know stops both, unstepped" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xDE }); // udf #0
    defer pair.close();
    const result = try step.one(&pair.cpu, pair.theirs);
    try std.testing.expectEqual(@as(u16, 0xDE00), result.stopped.unknown.hw1);
    try std.testing.expectEqual(pair_mod.entry, try pair.theirs.register(.pc));
}
