//! Conformance vectors for the decode group `divide` (RA8EMU-280): SDIV and
//! UDIV (T1). Expected values are worked from the Arm ARM (DDI0553): the
//! quotient rounds toward zero, a zero divisor gives 0 (CCR.DIV_0_TRP
//! clear), SDIV of INT_MIN by -1 wraps to INT_MIN, and neither touches the
//! flags. SP or PC in any field is UNPREDICTABLE and left unclaimed, as are
//! wrong fixed bits and the neighbouring long-multiply encodings.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rn and Rm before the instruction (Rm is written second).
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "divide";
const none: Out = .{ .claimed = false, .flags = 0 };

/// SDIV r0, r1, r2 and UDIV r0, r1, r2.
const sdiv = 0xFB91;
const udiv = 0xFBB1;
const r0_r2 = 0xF0F2;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn neg(x: u32) u32 {
    return 0 -% x;
}

pub const all = [_]V{
    vec("sdiv 7 / 2", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = 7, .m = 2 }, .{ .rd = 3 }),
    vec("sdiv -7 / 2 rounds toward zero", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = neg(7), .m = 2 }, .{ .rd = neg(3) }),
    vec("sdiv 7 / -2", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = 7, .m = neg(2) }, .{ .rd = neg(3) }),
    vec("sdiv -7 / -2", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = neg(7), .m = neg(2) }, .{ .rd = 3 }),
    vec("sdiv by zero gives 0", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = 0x1234_5678, .m = 0 }, .{ .rd = 0 }),
    vec("sdiv INT_MIN / -1 wraps", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = 0x8000_0000, .m = neg(1) }, .{ .rd = 0x8000_0000 }),
    vec("sdiv INT_MIN / 1", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = 0x8000_0000, .m = 1 }, .{ .rd = 0x8000_0000 }),
    vec("sdiv INT_MAX / -1", .{ .hw1 = sdiv, .hw2 = r0_r2, .n = 0x7FFF_FFFF, .m = neg(1) }, .{ .rd = 0x8000_0001 }),
    vec("udiv 7 / 2", .{ .hw1 = udiv, .hw2 = r0_r2, .n = 7, .m = 2 }, .{ .rd = 3 }),
    vec("udiv 0xffffffff / 2 is unsigned", .{ .hw1 = udiv, .hw2 = r0_r2, .n = 0xFFFF_FFFF, .m = 2 }, .{ .rd = 0x7FFF_FFFF }),
    vec("udiv 0xfffffff9 / 2", .{ .hw1 = udiv, .hw2 = r0_r2, .n = neg(7), .m = 2 }, .{ .rd = 0x7FFF_FFFC }),
    vec("udiv by zero gives 0", .{ .hw1 = udiv, .hw2 = r0_r2, .n = 0xFFFF_FFFF, .m = 0 }, .{ .rd = 0 }),
    vec("udiv 5 / 7 is 0", .{ .hw1 = udiv, .hw2 = r0_r2, .n = 5, .m = 7 }, .{ .rd = 0 }),
    vec("udiv 0x80000000 / 0xffffffff is 0", .{ .hw1 = udiv, .hw2 = r0_r2, .n = 0x8000_0000, .m = 0xFFFF_FFFF }, .{ .rd = 0 }),
    vec("sdiv r12, lr, r3", .{ .hw1 = 0xFB9E, .hw2 = 0xFCF3, .n = 100, .m = 7 }, .{ .rd = 14 }),
    vec("udiv r1, r1, r2 overwrites Rn", .{ .hw1 = 0xFBB1, .hw2 = 0xF1F2, .n = 100, .m = 10 }, .{ .rd = 10 }),
    vec("Rd of sp is unclaimed", .{ .hw1 = sdiv, .hw2 = 0xFDF2 }, none),
    vec("Rn of pc is unclaimed", .{ .hw1 = 0xFB9F, .hw2 = r0_r2 }, none),
    vec("Rm of sp is unclaimed", .{ .hw1 = udiv, .hw2 = 0xF0FD }, none),
    vec("wrong fixed bits are unclaimed", .{ .hw1 = sdiv, .hw2 = 0xF0E2 }, none),
    vec("smull belongs to long_mul", .{ .hw1 = 0xFB81, .hw2 = 0x0002 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = sdiv, .hw2 = r0_r2, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
