//! Conformance vectors for the decode group `mul_acc` (RA8EMU-280): MUL
//! (T2), MLA and MLS (T1). Expected values are worked from the Arm ARM
//! (DDI0553): Rd = Rn * Rm, plus Ra for MLA and subtracted from Ra for MLS,
//! keeping the low 32 bits; none touch the flags. MUL is MLA with Ra of PC.
//! SP or PC in Rd, Rn or Rm, Ra of SP, MLS with Ra of PC, the other op2
//! values and the long multiplies are left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Ra, then Rn, then Rm before the instruction.
    a: u32 = 0,
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
const group = "mul_acc";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rd r0, Rn r1, Rm r2, and Ra r3 for MLA and MLS.
const hw1 = 0xFB01;
const mul = 0xF002;
const mla = 0x3002;
const mls = 0x3012;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw2: u16, a: u32, n: u32, m: u32) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .a = a, .n = n, .m = m };
}

pub const all = [_]V{
    vec("mul 6 * 7", in(mul, 0, 6, 7), .{ .rd = 42 }),
    vec("mul keeps the low word of all-ones squared", in(mul, 0, 0xFFFF_FFFF, 0xFFFF_FFFF), .{ .rd = 1 }),
    vec("mul 0x10000 squared is 0", in(mul, 0, 0x1_0000, 0x1_0000), .{ .rd = 0 }),
    vec("mul 0x80000000 * 3", in(mul, 0, 0x8000_0000, 3), .{ .rd = 0x8000_0000 }),
    vec("mul of mixed bits", in(mul, 0, 0x1234_5678, 0x9ABC_DEF0), .{ .rd = 0x242D_2080 }),
    vec("mla 100 + 6 * 7", in(mla, 100, 6, 7), .{ .rd = 142 }),
    vec("mla wraps", in(mla, 0xFFFF_FFFF, 1, 1), .{ .rd = 0 }),
    vec("mla 5 + -2 * 3", in(mla, 5, 0xFFFF_FFFE, 3), .{ .rd = 0xFFFF_FFFF }),
    vec("mls 100 - 6 * 7", in(mls, 100, 6, 7), .{ .rd = 58 }),
    vec("mls 0 - 1 * 1 wraps", in(mls, 0, 1, 1), .{ .rd = 0xFFFF_FFFF }),
    vec("mls 5 - -2 * 3", in(mls, 5, 0xFFFF_FFFE, 3), .{ .rd = 11 }),
    vec("mls subtracts only the low word", in(mls, 0x10, 0x1_0000, 0x1_0000), .{ .rd = 0x10 }),
    vec("mul r12, lr, r4", .{ .hw1 = 0xFB0E, .hw2 = 0xFC04, .n = 3, .m = 5 }, .{ .rd = 15 }),
    vec("mla r1, r1, r2, r1 reads before writing", .{ .hw1 = hw1, .hw2 = 0x1102, .n = 3, .m = 4 }, .{ .rd = 15 }),
    vec("Rd of sp is unclaimed", .{ .hw1 = hw1, .hw2 = 0x3D02 }, none),
    vec("mul Rd of pc is unclaimed", .{ .hw1 = hw1, .hw2 = 0xFF02 }, none),
    vec("Rn of pc is unclaimed", .{ .hw1 = 0xFB0F, .hw2 = mla }, none),
    vec("Rm of sp is unclaimed", .{ .hw1 = hw1, .hw2 = 0x300D }, none),
    vec("mla Ra of sp is unclaimed", .{ .hw1 = hw1, .hw2 = 0xD002 }, none),
    vec("mls Ra of pc is unclaimed", .{ .hw1 = hw1, .hw2 = 0xF012 }, none),
    vec("another op2 is unclaimed", .{ .hw1 = hw1, .hw2 = 0x3022 }, none),
    vec("smull belongs to long_mul", .{ .hw1 = 0xFB81, .hw2 = 0x0002 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = hw1, .hw2 = mla, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
