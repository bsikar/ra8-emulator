//! Conformance vectors for the decode group `reverse` (RA8EMU-279): 16-bit
//! REV, REV16 and REVSH (T1). Each expected value is worked from the Arm ARM
//! (DDI0553) byte assignments, with NZCV untouched. op 0b10 of the space is
//! unallocated on Armv8-M and must not be claimed.
const vector = @import("../vector.zig");

/// The instruction, the value in Rm ([5:3]) and NZCV beforehand.
pub const In = struct {
    hw1: u16,
    rm: u32,
    nzcv: u4 = 0,
};

/// Whether the group claims the encoding, then Rd ([2:0]) and NZCV
/// afterwards (both zero when unclaimed).
pub const Out = struct {
    claimed: bool = true,
    rd: u32,
    nzcv: u4,
};

const V = vector.Vector(In, Out);
const group = "reverse";

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("rev r0, r1", .{ .hw1 = 0xBA08, .rm = 0x1234_5678, .nzcv = 0xF }, .{ .rd = 0x7856_3412, .nzcv = 0xF }),
    vec("rev r1, r1: Rd is Rm", .{ .hw1 = 0xBA09, .rm = 0xAABB_CCDD }, .{ .rd = 0xDDCC_BBAA, .nzcv = 0 }),
    vec("rev16 r0, r1", .{ .hw1 = 0xBA48, .rm = 0x1234_5678 }, .{ .rd = 0x3412_7856, .nzcv = 0 }),
    vec("revsh r0, r1: negative result", .{ .hw1 = 0xBAC8, .rm = 0x1234_0080 }, .{ .rd = 0xFFFF_8000, .nzcv = 0 }),
    vec("revsh r0, r1: positive result", .{ .hw1 = 0xBAC8, .rm = 0xFFFF_7F12, .nzcv = 0x4 }, .{ .rd = 0x0000_127F, .nzcv = 0x4 }),
    vec("op 0b10 is unallocated", .{ .hw1 = 0xBA88, .rm = 0x1234_5678 }, .{ .claimed = false, .rd = 0, .nzcv = 0 }),
};

pub const covered = vector.encodingsOf(In, Out, &all);
