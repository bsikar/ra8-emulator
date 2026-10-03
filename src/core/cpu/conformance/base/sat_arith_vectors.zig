//! Conformance vectors for the decode group `sat_arith` (RA8EMU-280): QADD,
//! QDADD, QSUB and QDSUB (T1). Expected values are worked from the Arm ARM
//! (DDI0553): QADD is SignedSat(Rm + Rn), QSUB is SignedSat(Rm - Rn), and
//! the D forms first replace Rn with SignedSat(2 * Rn). Any clamp, the
//! doubling's included, sets APSR.Q, which is sticky; NZCV are untouched.
//! SP or PC in any register, a wrong hw2[15:12] or hw2[7:6] and SEL are left
//! unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;
/// The flags after a clamp: N and C with Q set.
pub const flags_q: u32 = 0xA800_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// APSR.Q before the instruction.
    q: bool = false,
    /// Rn, then Rm, before the instruction.
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and NZCVQ after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "sat_arith";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 carries Rd r0, op2 and Rm r2.
const hw1 = 0xFA81;
const qadd = 0xF082;
const qdadd = 0xF092;
const qsub = 0xF0A2;
const qdsub = 0xF0B2;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// `m` is Rm and `n` is Rn; `q` is whether APSR.Q ends up set.
fn sat(name: []const u8, hw2: u16, m: u32, n: u32, rd: u32, q: bool) V {
    const input: In = .{ .hw1 = hw1, .hw2 = hw2, .n = n, .m = m };
    return vec(name, input, .{ .rd = rd, .flags = if (q) flags_q else flags });
}

fn bad(name: []const u8, h1: u16, h2: u16) V {
    return vec(name, .{ .hw1 = h1, .hw2 = h2 }, none);
}

pub const all = [_]V{
    sat("qadd in range", qadd, 1, 2, 3, false),
    sat("qadd of opposite signs", qadd, 0xFFFF_FFFB, 3, 0xFFFF_FFFE, false),
    sat("qadd of the extremes does not clamp", qadd, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, false),
    sat("qadd clamps high", qadd, 0x7FFF_FFFF, 1, 0x7FFF_FFFF, true),
    sat("qadd clamps low", qadd, 0x8000_0000, 0xFFFF_FFFF, 0x8000_0000, true),
    sat("qsub in range is Rm - Rn", qsub, 5, 3, 2, false),
    sat("qsub clamps low", qsub, 0x8000_0000, 1, 0x8000_0000, true),
    sat("qsub clamps high", qsub, 0x7FFF_FFFF, 0xFFFF_FFFF, 0x7FFF_FFFF, true),
    sat("qsub of the most negative Rn clamps", qsub, 0, 0x8000_0000, 0x7FFF_FFFF, true),
    sat("qdadd in range is Rm + 2Rn", qdadd, 1, 3, 7, false),
    sat("qdadd sets Q when only the doubling clamps", qdadd, 0xFFFF_FFFF, 0x4000_0000, 0x7FFF_FFFE, true),
    sat("qdadd clamps the sum", qdadd, 0x4000_0000, 0x2000_0000, 0x7FFF_FFFF, true),
    sat("qdadd doubling to exactly -2^31 does not clamp", qdadd, 0, 0xC000_0000, 0x8000_0000, false),
    sat("qdsub in range is Rm - 2Rn", qdsub, 10, 3, 4, false),
    sat("qdsub of a large negative Rn", qdsub, 0, 0xC000_0001, 0x7FFF_FFFE, false),
    sat("qdsub sets Q from the doubling though the result is exact", qdsub, 0x8000_0000, 0x8000_0000, 0, true),
    vec("Q is sticky", .{ .hw1 = hw1, .hw2 = qadd, .q = true, .n = 2, .m = 1 }, .{ .rd = 3, .flags = flags_q }),
    vec("qadd r12, lr, r4", .{ .hw1 = 0xFA8E, .hw2 = 0xFC84, .n = 0x10, .m = 0x100 }, .{ .rd = 0x110 }),
    vec("qdadd r1, r1, r1 reads before writing", .{ .hw1 = hw1, .hw2 = 0xF191, .n = 3, .m = 3 }, .{ .rd = 9 }),
    bad("Rd of sp is unclaimed", hw1, 0xFD82),
    bad("Rd of pc is unclaimed", hw1, 0xFF82),
    bad("Rn of sp is unclaimed", 0xFA8D, qadd),
    bad("Rn of pc is unclaimed", 0xFA8F, qadd),
    bad("Rm of sp is unclaimed", hw1, 0xF08D),
    bad("Rm of pc is unclaimed", hw1, 0xF08F),
    bad("hw2[7:6] of 11 is unclaimed", hw1, 0xF0C2),
    bad("hw2[7:6] of 01 is unclaimed", hw1, 0xF042),
    bad("a wrong hw2[15:12] is unclaimed", hw1, 0xE082),
    bad("sel belongs to its own group", 0xFAA1, qadd),
    vec("the 16-bit space is unclaimed", .{ .hw1 = hw1, .hw2 = qadd, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
