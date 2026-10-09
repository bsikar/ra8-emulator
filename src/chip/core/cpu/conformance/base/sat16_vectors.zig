//! Conformance vectors for the decode group `sat16` (RA8EMU-280): SSAT16 and
//! USAT16 (T1). Expected values are worked from the Arm ARM (DDI0553): each
//! halfword of Rn is saturated on its own, SSAT16 to a signed range of
//! sat_imm + 1 bits and USAT16 to an unsigned range of sat_imm bits. Any
//! clamp sets APSR.Q, which is sticky; NZCV are untouched. SP or PC in Rd or
//! Rn, a set hw2[15], imm3, imm2 or hw2[5:4] and plain SSAT are left
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
    /// Rn before the instruction.
    n: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and NZCVQ after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "sat16";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 carries Rd r0 and sat_imm.
const ssat16 = 0xF321;
const usat16 = 0xF3A1;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn sat(name: []const u8, hw1: u16, imm: u4, n: u32, rd: u32, q: bool) V {
    const input: In = .{ .hw1 = hw1, .hw2 = imm, .n = n };
    return vec(name, input, .{ .rd = rd, .flags = if (q) flags_q else flags });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    sat("ssat16 #8 keeps in-range halves", ssat16, 7, 0x0010_FFF0, 0x0010_FFF0, false),
    sat("ssat16 #8 clamps both halves", ssat16, 7, 0x0100_FE00, 0x007F_FF80, true),
    sat("ssat16 #8 clamps only the high half", ssat16, 7, 0x7FFF_0005, 0x007F_0005, true),
    sat("ssat16 #8 clamps only the low half", ssat16, 7, 0x0005_8000, 0x0005_FF80, true),
    sat("ssat16 #1 clamps 1 to 0", ssat16, 0, 0x0001_FFFF, 0x0000_FFFF, true),
    sat("ssat16 #1 keeps 0 and -1", ssat16, 0, 0x0000_FFFF, 0x0000_FFFF, false),
    sat("ssat16 #16 never clamps", ssat16, 15, 0x8000_7FFF, 0x8000_7FFF, false),
    sat("usat16 #8 clamps 256 and -1", usat16, 8, 0x0100_FFFF, 0x00FF_0000, true),
    sat("usat16 #8 keeps in-range halves", usat16, 8, 0x0080_00FF, 0x0080_00FF, false),
    sat("usat16 #0 clamps everything to zero", usat16, 0, 0x0001_0000, 0, true),
    sat("usat16 #15 clamps a negative half only", usat16, 15, 0x8000_7FFF, 0x0000_7FFF, true),
    vec("Q is sticky", .{ .hw1 = ssat16, .hw2 = 0x0007, .q = true, .n = 5 }, .{ .rd = 5, .flags = flags_q }),
    vec("ssat16 r12, lr, #8", .{ .hw1 = 0xF32E, .hw2 = 0x0C07, .n = 0x0200_0003 }, .{ .rd = 0x007F_0003, .flags = flags_q }),
    vec("ssat16 r1, r1, #8 reads before writing", .{ .hw1 = ssat16, .hw2 = 0x0107, .n = 0x0100_0001 }, .{ .rd = 0x007F_0001, .flags = flags_q }),
    bad("Rd of sp is unclaimed", ssat16, 0x0D07),
    bad("Rd of pc is unclaimed", ssat16, 0x0F07),
    bad("Rn of sp is unclaimed", 0xF32D, 0x0007),
    bad("Rn of pc is unclaimed", 0xF3AF, 0x0007),
    bad("a set hw2[15] is unclaimed", ssat16, 0x8007),
    bad("a non-zero imm3 is unclaimed", ssat16, 0x1007),
    bad("a non-zero imm2 is unclaimed", ssat16, 0x0047),
    bad("a set hw2[5:4] is unclaimed", usat16, 0x0018),
    bad("plain ssat belongs to saturate", 0xF301, 0x0007),
    vec("the 16-bit space is unclaimed", .{ .hw1 = ssat16, .hw2 = 0x0007, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
