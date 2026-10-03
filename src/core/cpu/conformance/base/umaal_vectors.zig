//! Conformance vectors for the decode group `umaal` (RA8EMU-280): UMAAL
//! (T1). Expected values are worked from the Arm ARM (DDI0553):
//! RdHi:RdLo = Rn * Rm + RdHi + RdLo, all unsigned, which always fits in 64
//! bits; no flags change. SP or PC anywhere, RdLo == RdHi, the UMLAL row
//! and other hw2[7:4] values are left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// RdLo, RdHi, Rn, then Rm before the instruction, written in that order.
    lo: u32 = 0,
    hi: u32 = 0,
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then RdLo, RdHi and NZCV after.
pub const Out = struct {
    claimed: bool = true,
    lo: u32 = 0,
    hi: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "umaal";
const none: Out = .{ .claimed = false, .flags = 0 };

/// umaal r0, r1, r2, r3.
const umaal = 0xFBE2;
const plain = 0x0163;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn acc(name: []const u8, n: u32, m: u32, hi: u32, lo: u32, out_hi: u32, out_lo: u32) V {
    const input: In = .{ .hw1 = umaal, .hw2 = plain, .lo = lo, .hi = hi, .n = n, .m = m };
    return vec(name, input, .{ .lo = out_lo, .hi = out_hi });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    acc("a small product", 2, 3, 0, 0, 0, 6),
    acc("a zero product keeps the sum of RdHi and RdLo", 0x1234_5678, 0, 5, 7, 0, 12),
    acc("the product carries into RdHi", 0x1_0000, 0x1_0000, 0, 0, 1, 0),
    acc("adding RdLo carries into RdHi", 1, 0xFFFF_FFFF, 1, 0, 1, 0),
    acc("both addends are summed", 0x8000_0000, 2, 0x10, 0x20, 1, 0x30),
    acc("a wide product with both addends", 0xDEAD_BEEF, 0x1234_5678, 0x1111_1111, 0x2222_2222, 0x0FD5_BDEE, 0x8954_FD3B),
    acc("the largest operands just fit in 64 bits", 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF),
    vec("Rn may be RdLo and is read first", .{ .hw1 = 0xFBE0, .hw2 = plain, .lo = 3, .hi = 10, .n = 3, .m = 4 }, .{ .lo = 25, .hi = 0 }),
    vec("umaal r12, lr, r4, r5", .{ .hw1 = 0xFBE4, .hw2 = 0xCE65, .lo = 1, .hi = 2, .n = 0x100, .m = 0x200 }, .{ .lo = 0x2_0003, .hi = 0 }),
    bad("RdLo equal to RdHi is unclaimed", umaal, 0x1163),
    bad("Rn of sp is unclaimed", 0xFBED, plain),
    bad("Rn of pc is unclaimed", 0xFBEF, plain),
    bad("Rm of sp is unclaimed", umaal, 0x016D),
    bad("Rm of pc is unclaimed", umaal, 0x016F),
    bad("RdLo of sp is unclaimed", umaal, 0xD163),
    bad("RdHi of pc is unclaimed", umaal, 0x0F63),
    bad("umlal belongs to long_mul", umaal, 0x0103),
    bad("hw2[7:4] of 0111 is not umaal", umaal, 0x0173),
    bad("smlal (0xFBC0) is not umaal", 0xFBC2, plain),
    vec("the 16-bit space is unclaimed", .{ .hw1 = umaal, .hw2 = plain, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
