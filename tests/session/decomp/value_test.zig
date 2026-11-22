//! Covers src/session/decomp/value.zig.
const std = @import("std");
const ra8 = @import("ra8");

const val = ra8.session.decomp.value;

test "value lattice joins constants, sp offsets, entry regs, and pairs monotonically" {
    const c1: val.Value = .{ .constant = 42 };
    const c2: val.Value = .{ .constant = 42 };
    const c3: val.Value = .{ .constant = 99 };
    try std.testing.expect(c1.eql(c2));
    try std.testing.expect(!c1.eql(c3));

    try std.testing.expect(val.joinValue(.unvisited, c1).eql(c1));
    try std.testing.expect(val.joinValue(c1, .unvisited).eql(c1));
    try std.testing.expect(val.joinValue(c1, c2).eql(c1));
    try std.testing.expectEqual(val.Value.unknown, val.joinValue(c1, c3));

    const sp8: val.Value = .{ .sp_offset = -8 };
    try std.testing.expectEqual(val.Value{ .sp_offset = 0 }, val.evalAdd(sp8, 8));
    try std.testing.expectEqual(val.Value{ .constant = 50 }, val.evalAdd(c1, 8));
    try std.testing.expectEqual(val.Value.unknown, val.evalAdd(.unknown, 8));
}

test "joinFlags keeps identical setter origins and drops conflicting setters to unknown" {
    const a: val.FlagState = .{ .known = .{
        .setter_insn = 3,
        .setter_addr = 0x100,
        .kind = .cmp,
        .lhs_reg = 3,
        .rhs_imm = 0,
        .lhs_val = .{ .constant = 5 },
    } };
    const b: val.FlagState = .{ .known = .{
        .setter_insn = 3,
        .setter_addr = 0x100,
        .kind = .cmp,
        .lhs_reg = 3,
        .rhs_imm = 0,
        .lhs_val = .{ .constant = 9 },
    } };
    const c: val.FlagState = .{ .known = .{
        .setter_insn = 7,
        .setter_addr = 0x108,
        .kind = .cmp,
        .lhs_reg = 2,
        .rhs_imm = 1,
    } };

    try std.testing.expect(val.joinFlags(.unvisited, a).eql(a));
    const merged = val.joinFlags(a, b);
    try std.testing.expectEqual(@as(u32, 3), merged.known.setter_insn);
    try std.testing.expectEqual(val.Value.unknown, merged.known.lhs_val);
    try std.testing.expectEqual(val.FlagState.unknown, val.joinFlags(a, c));
}
