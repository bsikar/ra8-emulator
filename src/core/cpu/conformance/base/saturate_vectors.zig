//! Conformance vectors for the decode group `saturate` (RA8EMU-280): SSAT
//! and USAT (T1). Expected values are worked from the Arm ARM (DDI0553):
//! Rn shifted by LSL #0..31 or ASR #1..31, then SignedSatQ to sat_imm + 1
//! bits or UnsignedSatQ to sat_imm bits. A clamp sets the sticky APSR.Q and
//! NZCV never change. SP or PC in Rd or Rn, the ASR #0 forms (SSAT16 and
//! USAT16), a set hw2[5] or hw2[15] and the bitfield neighbours are left
//! unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;
/// APSR.Q.
pub const q: u32 = 0x0800_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
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
const group = "saturate";
const none: Out = .{ .claimed = false, .flags = 0 };
const sat: u32 = flags | q;

/// SSAT and USAT with Rn r1, plain (LSL) and with ASR.
const ssat = 0xF301;
const ssat_asr = 0xF321;
const usat = 0xF381;
const usat_asr = 0xF3A1;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw1: u16, hw2: u16, n: u32) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .n = n };
}

pub const all = [_]V{
    vec("ssat #8 in range", in(ssat, 0x0007, 100), .{ .rd = 100 }),
    vec("ssat #8 clamps high", in(ssat, 0x0007, 200), .{ .rd = 127, .flags = sat }),
    vec("ssat #8 clamps low", in(ssat, 0x0007, 0xFFFF_FF38), .{ .rd = 0xFFFF_FF80, .flags = sat }),
    vec("ssat #8 at the bottom edge", in(ssat, 0x0007, 0xFFFF_FF80), .{ .rd = 0xFFFF_FF80 }),
    vec("ssat #32 never clamps", in(ssat, 0x001F, 0x8000_0000), .{ .rd = 0x8000_0000 }),
    vec("ssat #1 clamps 1 to 0", in(ssat, 0x0000, 1), .{ .rd = 0, .flags = sat }),
    vec("ssat #1 clamps -5 to -1", in(ssat, 0x0000, 0xFFFF_FFFB), .{ .rd = 0xFFFF_FFFF, .flags = sat }),
    vec("ssat #16, lsl #4 clamps", in(ssat, 0x100F, 0x1000), .{ .rd = 0x7FFF, .flags = sat }),
    vec("ssat #16, asr #4 clamps", in(ssat_asr, 0x100F, 0x8000_0000), .{ .rd = 0xFFFF_8000, .flags = sat }),
    vec("ssat #8, asr #31", in(ssat_asr, 0x70C7, 0x8000_0000), .{ .rd = 0xFFFF_FFFF }),
    vec("ssat #32, lsl #31", in(ssat, 0x70DF, 1), .{ .rd = 0x8000_0000 }),
    vec("usat #8 at the top edge", in(usat, 0x0008, 255), .{ .rd = 255 }),
    vec("usat #8 clamps high", in(usat, 0x0008, 256), .{ .rd = 255, .flags = sat }),
    vec("usat #8 clamps a negative to 0", in(usat, 0x0008, 0xFFFF_FFFF), .{ .rd = 0, .flags = sat }),
    vec("usat #0 clamps 5 to 0", in(usat, 0x0000, 5), .{ .rd = 0, .flags = sat }),
    vec("usat #0 leaves 0", in(usat, 0x0000, 0), .{ .rd = 0 }),
    vec("usat #31 at the top edge", in(usat, 0x001F, 0x7FFF_FFFF), .{ .rd = 0x7FFF_FFFF }),
    vec("usat #31 clamps a negative to 0", in(usat, 0x001F, 0x8000_0000), .{ .rd = 0, .flags = sat }),
    vec("usat #16, asr #8 clamps", in(usat_asr, 0x2010, 0x0123_4500), .{ .rd = 0xFFFF, .flags = sat }),
    vec("ssat r12, #8, lr", in(0xF30E, 0x0C07, 5), .{ .rd = 5 }),
    vec("Rd of sp is unclaimed", in(ssat, 0x0D07, 0), none),
    vec("Rd of pc is unclaimed", in(ssat, 0x0F07, 0), none),
    vec("Rn of sp is unclaimed", in(0xF30D, 0x0007, 0), none),
    vec("Rn of pc is unclaimed", in(0xF30F, 0x0007, 0), none),
    vec("ssat asr #0 is ssat16", in(ssat_asr, 0x0007, 0), none),
    vec("usat asr #0 is usat16", in(usat_asr, 0x0008, 0), none),
    vec("a set hw2[5] is unclaimed", in(ssat, 0x0027, 0), none),
    vec("a set hw2[15] is unclaimed", in(ssat, 0x8007, 0), none),
    vec("a set hw1[4] is unclaimed", in(0xF311, 0x0007, 0), none),
    vec("sbfx belongs to bitfield", in(0xF341, 0x0007, 0), none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = ssat, .hw2 = 0x0007, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
