//! Tests for DWARF variable location classification and frame-base evaluation.
const std = @import("std");
const ra8 = @import("ra8");

const var_loc = ra8.session.dwarf.var_loc;
const unwind = ra8.session.unwind;
const dwarf = std.dwarf;

test "var_loc.classify handles single writable ops and rejects complex or read-only ops" {
    try std.testing.expectEqualDeep(
        var_loc.Location{ .frame = -16 },
        var_loc.classify(dwarf.FORM.exprloc, &.{ dwarf.OP.fbreg, 0x70 }, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .in_register = 5 },
        var_loc.classify(dwarf.FORM.exprloc, &.{dwarf.OP.reg5}, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .register_offset = .{ .reg = 13, .offset = 8 } },
        var_loc.classify(dwarf.FORM.exprloc, &.{ dwarf.OP.breg13, 0x08 }, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .address = 0x2200_0100 },
        var_loc.classify(dwarf.FORM.exprloc, &.{ dwarf.OP.addr, 0x00, 0x01, 0x00, 0x22 }, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .read_only = .const_value },
        var_loc.classify(null, null, true, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .read_only = .optimized_out },
        var_loc.classify(null, null, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .read_only = .location_list },
        var_loc.classify(dwarf.FORM.sec_offset, null, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .read_only = .composite },
        var_loc.classify(dwarf.FORM.exprloc, &.{ dwarf.OP.reg0, dwarf.OP.piece, 0x04 }, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .read_only = .implicit_value },
        var_loc.classify(dwarf.FORM.exprloc, &.{ dwarf.OP.lit1, dwarf.OP.stack_value }, false, 4),
    );
    try std.testing.expectEqualDeep(
        var_loc.Location{ .read_only = .multi_op },
        var_loc.classify(dwarf.FORM.exprloc, &.{ dwarf.OP.fbreg, 0x7c, dwarf.OP.deref }, false, 4),
    );
}

test "var_loc.frameBaseAddress evaluates register and breg bases" {
    var regs = std.mem.zeroes(unwind.Registers);
    regs[13] = 0x2200_2000;
    try std.testing.expectEqual(@as(u32, 0x2200_2000), try var_loc.frameBaseAddress(&.{}, &.{dwarf.OP.reg13}, regs));
    try std.testing.expectEqual(@as(u32, 0x2200_2010), try var_loc.frameBaseAddress(&.{}, &.{ dwarf.OP.breg13, 0x10 }, regs));
    try std.testing.expectError(error.MissingFrameBase, var_loc.frameBaseAddress(&.{}, &.{}, regs));
    try std.testing.expect(var_loc.reasonText(.missing_frame_base).len > 0);
}
