//! Conformance vectors for the decode group `parallel` (RA8EMU-280): the
//! DSP parallel ADD16, ASX, SAX, SUB16, ADD8 and SUB8 (T1) with the S, Q,
//! SH, U, UQ and UH prefixes. Expected values are worked from the Arm ARM
//! (DDI0553): each lane is worked on its own; the modular S and U forms
//! write all four APSR.GE bits, while the saturating and halving forms leave
//! GE and Q alone. NZCV are never touched. SP or PC in any register, op1 011
//! and 111, op2 11, a wrong hw2[15:12] and the hw2[7] rows are left
//! unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// APSR.GE before the instruction.
    ge: u4 = 0,
    /// Rn, then Rm, before the instruction.
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd, NZCVQ and GE after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
    ge: u4 = 0,
};

const V = vector.Vector(In, Out);
const group = "parallel";
const none: Out = .{ .claimed = false, .flags = 0 };

/// hw1 by op1 with Rn r1.
const add8 = 0xFA81;
const add16 = 0xFA91;
const asx = 0xFAA1;
const sub8 = 0xFAC1;
const sub16 = 0xFAD1;
const sax = 0xFAE1;
/// hw2 by prefix with Rd r0 and Rm r2.
const s = 0xF002;
const q = 0xF012;
const sh = 0xF022;
const u = 0xF042;
const uq = 0xF052;
const uh = 0xF062;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// A modular form: GE starts as `ge_in` and ends as `ge`.
fn mod(name: []const u8, hw1: u16, hw2: u16, n: u32, m: u32, rd: u32, ge_in: u4, ge: u4) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .ge = ge_in, .n = n, .m = m }, .{ .rd = rd, .ge = ge });
}

/// A saturating or halving form: GE 0101 goes in and must survive.
fn keep(name: []const u8, hw1: u16, hw2: u16, n: u32, m: u32, rd: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .ge = 0x5, .n = n, .m = m }, .{ .rd = rd, .ge = 0x5 });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    mod("sadd16 wraps a lane and sets GE on non-negative sums", add16, s, 0x7FFF_0001, 0x0001_0001, 0x8000_0002, 0, 0xF),
    mod("sadd16 negative sums clear every GE bit", add16, s, 0xFFFF_8000, 0xFFFF_FFFF, 0xFFFE_7FFF, 0xF, 0),
    mod("uadd16 sets GE on a lane carry", add16, u, 0xFFFF_0001, 0x0001_0001, 0x0000_0002, 0, 0xC),
    mod("ssub16 sets GE on non-negative differences", sub16, s, 0x0005_0003, 0x0003_0005, 0x0002_FFFE, 0, 0xC),
    mod("usub16 sets GE where no borrow", sub16, u, 0x0005_0003, 0x0003_0005, 0x0002_FFFE, 0, 0xC),
    mod("sadd8 per-byte GE", add8, s, 0x7F80_0102, 0x0180_FF01, 0x8000_0003, 0, 0xB),
    mod("uadd8 per-byte carries", add8, u, 0xFF80_0102, 0x0180_FF01, 0x0000_0003, 0, 0xE),
    mod("ssub8 per-byte GE", sub8, s, 0x807F_0005, 0x01FF_0103, 0x7F80_FF02, 0, 0x5),
    mod("usub8 per-byte borrows", sub8, u, 0x0010_0302, 0x0110_0201, 0xFF00_0101, 0, 0x7),
    mod("sasx subtracts low and adds high, crossed", asx, s, 0x0010_0020, 0x0003_0005, 0x0015_001D, 0, 0xF),
    mod("ssax adds low and subtracts high, crossed", sax, s, 0x0010_0020, 0x0030_0020, 0xFFF0_0050, 0, 0x3),
    mod("uasx GE from the borrow and the carry", asx, u, 0xFFFF_0001, 0x0002_0001, 0x0000_FFFF, 0, 0xC),
    keep("qadd16 saturates both ways", add16, q, 0x7FFF_8000, 0x0001_FFFF, 0x7FFF_8000),
    keep("qasx saturates both ways", asx, q, 0x7FFF_8000, 0x0001_0001, 0x7FFF_8000),
    keep("qsub8 saturates both ways", sub8, q, 0x807F_0000, 0x01FF_0000, 0x807F_0000),
    keep("uqadd8 clamps to 0xFF", add8, uq, 0xFF80_1001, 0x0180_1001, 0xFFFF_2002),
    keep("uqsub8 clamps to zero", sub8, uq, 0x0510_00FF, 0x0601_0101, 0x000F_00FE),
    keep("shadd16 halves the full sum", add16, sh, 0x7FFF_FFFF, 0x0001_FFFF, 0x4000_FFFF),
    keep("shsub8 halves with an arithmetic shift", sub8, sh, 0x8000_1004, 0x7F01_0001, 0x80FF_0801),
    keep("uhadd16 keeps the carry bit", add16, uh, 0xFFFF_0003, 0xFFFF_0000, 0xFFFF_0001),
    keep("uhsub16 of a borrow", sub16, uh, 0x0000_0010, 0x0002_0004, 0xFFFF_0006),
    keep("uhsax crossed halving", sax, uh, 0x0010_FFFF, 0xFFFF_0020, 0xFFF8_FFFF),
    vec("sadd8 r12, lr, r4", .{ .hw1 = 0xFA8E, .hw2 = 0xFC04, .n = 0x0101_0101, .m = 0x0202_0202 }, .{ .rd = 0x0303_0303, .ge = 0xF }),
    vec("uadd8 r1, r1, r1 reads before writing", .{ .hw1 = add8, .hw2 = 0xF141, .n = 0x8040_01FF, .m = 0x8040_01FF }, .{ .rd = 0x0080_02FE, .ge = 0x9 }),
    bad("op1 011 is unclaimed", 0xFAB1, s),
    bad("op1 111 is unclaimed", 0xFAF1, s),
    bad("op2 11 is unclaimed", add16, 0xF032),
    bad("Rd of sp is unclaimed", add16, 0xFD02),
    bad("Rd of pc is unclaimed", add16, 0xFF02),
    bad("Rn of sp is unclaimed", 0xFA9D, s),
    bad("Rn of pc is unclaimed", 0xFA9F, s),
    bad("Rm of sp is unclaimed", add16, 0xF00D),
    bad("Rm of pc is unclaimed", add16, 0xF00F),
    bad("qadd (hw2[7] set) belongs to sat_arith", add8, 0xF082),
    bad("a wrong hw2[15:12] is unclaimed", add16, 0xE002),
    vec("the 16-bit space is unclaimed", .{ .hw1 = add16, .hw2 = s, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
