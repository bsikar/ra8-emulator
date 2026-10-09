//! Conformance vectors for the decode group `misc_wide` (RA8EMU-280): REV,
//! REV16, RBIT and REVSH (T2/T1) and CLZ (T1). Expected values are worked
//! from the Arm ARM (DDI0553): byte and halfword reversals, the bit reversal,
//! REVSH's sign extension and the leading-zero count from 0 to 32, with the
//! flags untouched. Two Rm copies that differ, Rd or Rm of SP or PC, the
//! unallocated op2 values, a wrong hw2[15:12] and SEL are left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rm before the instruction.
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "misc_wide";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rd r0 and Rm r1 (in both copies).
const rev_rbit = 0xFA91;
const clz = 0xFAB1;
const rev = 0xF081;
const rev16 = 0xF091;
const rbit = 0xF0A1;
const revsh = 0xF0B1;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw1: u16, hw2: u16, m: u32) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .m = m };
}

pub const all = [_]V{
    vec("rev swaps all four bytes", in(rev_rbit, rev, 0x1234_5678), .{ .rd = 0x7856_3412 }),
    vec("rev16 swaps bytes in each halfword", in(rev_rbit, rev16, 0x1234_5678), .{ .rd = 0x3412_7856 }),
    vec("rbit of 1", in(rev_rbit, rbit, 1), .{ .rd = 0x8000_0000 }),
    vec("rbit of mixed bits", in(rev_rbit, rbit, 0x1234_5678), .{ .rd = 0x1E6A_2C48 }),
    vec("revsh of a positive halfword", in(rev_rbit, revsh, 0x1234_5678), .{ .rd = 0x0000_7856 }),
    vec("revsh sign-extends", in(rev_rbit, revsh, 0x1234_0080), .{ .rd = 0xFFFF_8000 }),
    vec("clz of 0 is 32", in(clz, rev, 0), .{ .rd = 32 }),
    vec("clz of 1 is 31", in(clz, rev, 1), .{ .rd = 31 }),
    vec("clz of bit 31 is 0", in(clz, rev, 0x8000_0000), .{ .rd = 0 }),
    vec("clz of bit 16 is 15", in(clz, rev, 0x0001_0000), .{ .rd = 15 }),
    vec("rev r12, lr", in(0xFA9E, 0xFC8E, 0x1122_3344), .{ .rd = 0x4433_2211 }),
    vec("Rm copies that differ are unclaimed", in(rev_rbit, 0xF082, 0), none),
    vec("Rd of sp is unclaimed", in(rev_rbit, 0xFD81, 0), none),
    vec("Rd of pc is unclaimed", in(rev_rbit, 0xFF81, 0), none),
    vec("Rm of sp is unclaimed", in(0xFA9D, 0xF08D, 0), none),
    vec("Rm of pc is unclaimed", in(0xFA9F, 0xF08F, 0), none),
    vec("clz with another op2 is unclaimed", in(clz, rev16, 0), none),
    vec("op2 1100 is unclaimed", in(rev_rbit, 0xF0C1, 0), none),
    vec("a wrong hw2[15:12] is unclaimed", in(rev_rbit, 0xE081, 0), none),
    vec("sel belongs to its own group", in(0xFAA1, 0xF081, 0), none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = rev_rbit, .hw2 = rev, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
