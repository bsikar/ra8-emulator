//! Conformance vectors for the decode group `csel` (RA8EMU-280): CSEL,
//! CSINC, CSINV and CSNEG (T1) and the CSET, CSETM and CINC aliases.
//! Expected values are worked from the Arm ARM (DDI0553): when the condition
//! holds Rd takes Rn; otherwise Rd takes Rm as is, plus one, inverted or
//! negated. Register 1111 in Rn or Rm reads as zero. None of them writes
//! NZCV, so each vector's flags must survive. SP in any register, Rd = 1111,
//! the AL and 1111 conditions and kinds outside 1000-1011 are left
//! unclaimed.
const vector = @import("../vector.zig");

const n_flag: u32 = 0x8000_0000;
const z_flag: u32 = 0x4000_0000;
const c_flag: u32 = 0x2000_0000;
const v_flag: u32 = 0x1000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// NZCV before the instruction.
    flags: u32 = 0,
    /// Rn, then Rm before the instruction (the zero register is never set).
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and NZCV after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = 0,
};

const V = vector.Vector(In, Out);
const group = "csel";
const none: Out = .{ .claimed = false };

/// Rn r1; `form` builds hw2 for a kind and condition with Rd r0 and Rm r2.
const rn1 = 0xEA51;
const zr = 0xEA5F;
const sel: u16 = 0x8;
const inc: u16 = 0x9;
const inv: u16 = 0xA;
const neg: u16 = 0xB;

fn form(kind: u16, cond: u16) u16 {
    return (kind << 12) | (cond << 4) | 2;
}

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// Rn = 0x11 and Rm = `m`; Rd is `rd` and the flags must survive.
fn pick(name: []const u8, kind: u16, cond: u16, flags: u32, m: u32, rd: u32) V {
    const input: In = .{ .hw1 = rn1, .hw2 = form(kind, cond), .flags = flags, .n = 0x11, .m = m };
    return vec(name, input, .{ .rd = rd, .flags = flags });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    pick("csel eq taken", sel, 0x0, z_flag, 0x22, 0x11),
    pick("csel eq not taken", sel, 0x0, 0, 0x22, 0x22),
    pick("csinc ne not taken wraps", inc, 0x1, z_flag, 0xFFFF_FFFF, 0),
    pick("csinc ne taken", inc, 0x1, 0, 0xFFFF_FFFF, 0x11),
    pick("csinv cs not taken", inv, 0x2, 0, 0x0F0F_0F0F, 0xF0F0_F0F0),
    pick("csneg cc not taken", neg, 0x3, c_flag, 1, 0xFFFF_FFFF),
    pick("csneg of the most negative", neg, 0x3, c_flag, 0x8000_0000, 0x8000_0000),
    pick("mi taken", sel, 0x4, n_flag, 0x22, 0x11),
    pick("pl not taken", sel, 0x5, n_flag, 0x22, 0x22),
    pick("vs taken", sel, 0x6, v_flag, 0x22, 0x11),
    pick("vc not taken", sel, 0x7, v_flag, 0x22, 0x22),
    pick("hi taken on C and not Z", sel, 0x8, c_flag, 0x22, 0x11),
    pick("hi not taken when Z is set too", sel, 0x8, c_flag | z_flag, 0x22, 0x22),
    pick("ls taken on Z", sel, 0x9, c_flag | z_flag, 0x22, 0x11),
    pick("ge taken when N equals V", sel, 0xA, n_flag | v_flag, 0x22, 0x11),
    pick("ge not taken when N differs from V", sel, 0xA, n_flag, 0x22, 0x22),
    pick("lt taken when N differs from V", sel, 0xB, v_flag, 0x22, 0x11),
    pick("gt taken on clear flags", sel, 0xC, 0, 0x22, 0x11),
    pick("gt not taken on Z", sel, 0xC, z_flag, 0x22, 0x22),
    pick("le taken on Z", sel, 0xD, z_flag, 0x22, 0x11),
    pick("le not taken on clear flags", sel, 0xD, 0, 0x22, 0x22),
    pick("every flag survives", inc, 0x0, 0xF000_0000, 0x22, 0x11),
    vec("cset eq when Z is set gives one", .{ .hw1 = zr, .hw2 = 0x901F, .flags = z_flag }, .{ .rd = 1, .flags = z_flag }),
    vec("cset eq when Z is clear gives zero", .{ .hw1 = zr, .hw2 = 0x901F }, .{ .rd = 0 }),
    vec("csetm eq when Z is set gives all ones", .{ .hw1 = zr, .hw2 = 0xA01F, .flags = z_flag }, .{ .rd = 0xFFFF_FFFF, .flags = z_flag }),
    vec("cinc ne when Z is clear adds one", .{ .hw1 = rn1, .hw2 = 0x9001, .n = 7, .m = 7 }, .{ .rd = 8 }),
    vec("csel r12, lr, r4, eq", .{ .hw1 = 0xEA5E, .hw2 = 0x8C04, .flags = z_flag, .n = 0x33, .m = 0x44 }, .{ .rd = 0x33, .flags = z_flag }),
    bad("Rd of sp is unclaimed", rn1, 0x8D02),
    bad("Rd of 1111 is unclaimed", rn1, 0x8F02),
    bad("Rn of sp is unclaimed", 0xEA5D, form(sel, 0)),
    bad("Rm of sp is unclaimed", rn1, 0x800D),
    bad("the AL condition is unclaimed", rn1, form(sel, 0xE)),
    bad("condition 1111 is unclaimed", rn1, form(sel, 0xF)),
    bad("kind 0111 is unclaimed", rn1, form(0x7, 0)),
    bad("kind 1100 is unclaimed", rn1, form(0xC, 0)),
    bad("a different first halfword is unclaimed", 0xEA41, form(sel, 0)),
    vec("the 16-bit space is unclaimed", .{ .hw1 = rn1, .hw2 = form(sel, 0), .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
