//! Conformance vectors for the decode group `bitfield` (RA8EMU-280): SBFX,
//! UBFX, BFI and BFC (T1). Expected values are worked from the Arm ARM
//! (DDI0553): lsb is imm3:imm2; the extracts take widthm1 + 1 bits from lsb
//! and sign- or zero-extend them; BFI copies Rn[msb-lsb:0] into Rd[msb:lsb]
//! and BFC (Rn = PC) clears that field; none touch the flags. An extract
//! running past bit 31, an insert with msb below lsb, Rd of SP or PC, Rn of
//! SP, an extract from PC and set fixed-zero bits are left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rd then Rn before the instruction (Rn is written second).
    d: u32 = 0,
    n: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "bitfield";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Each instruction with Rn = r1 (BFC has Rn = PC).
const sbfx = 0xF341;
const ubfx = 0xF3C1;
const bfi = 0xF361;
const bfc = 0xF36F;

/// hw2 for Rd, lsb and widthm1 (extracts) or msb (inserts).
fn h2(rd: u16, lsb: u16, top: u16) u16 {
    return ((lsb >> 2) << 12) | (rd << 8) | ((lsb & 3) << 6) | top;
}

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("ubfx r0, r1, #8, #8", .{ .hw1 = ubfx, .hw2 = h2(0, 8, 7), .n = 0x1234_5678 }, .{ .rd = 0x56 }),
    vec("ubfx #0, #32 is the whole word", .{ .hw1 = ubfx, .hw2 = h2(0, 0, 31), .n = 0xDEAD_BEEF }, .{ .rd = 0xDEAD_BEEF }),
    vec("ubfx #31, #1 is the top bit", .{ .hw1 = ubfx, .hw2 = h2(0, 31, 0), .n = 0x8000_0000 }, .{ .rd = 1 }),
    vec("ubfx #1, #3 uses imm2", .{ .hw1 = ubfx, .hw2 = h2(0, 1, 2), .n = 0xE }, .{ .rd = 7 }),
    vec("sbfx #8, #8 of a negative field", .{ .hw1 = sbfx, .hw2 = h2(0, 8, 7), .n = 0x0000_8000 }, .{ .rd = 0xFFFF_FF80 }),
    vec("sbfx #8, #8 of a positive field", .{ .hw1 = sbfx, .hw2 = h2(0, 8, 7), .n = 0x0000_7F00 }, .{ .rd = 0x7F }),
    vec("sbfx #0, #32 is the whole word", .{ .hw1 = sbfx, .hw2 = h2(0, 0, 31), .n = 0x8000_0001 }, .{ .rd = 0x8000_0001 }),
    vec("sbfx #31, #1 of a set top bit", .{ .hw1 = sbfx, .hw2 = h2(0, 31, 0), .n = 0x8000_0000 }, .{ .rd = 0xFFFF_FFFF }),
    vec("sbfx #4, #1 of a set bit", .{ .hw1 = sbfx, .hw2 = h2(0, 4, 0), .n = 0x10 }, .{ .rd = 0xFFFF_FFFF }),
    vec("bfi r0, r1, #8, #8", .{ .hw1 = bfi, .hw2 = h2(0, 8, 15), .d = 0xFFFF_FFFF, .n = 0x12 }, .{ .rd = 0xFFFF_12FF }),
    vec("bfi #0, #32 replaces the word", .{ .hw1 = bfi, .hw2 = h2(0, 0, 31), .d = 0xDEAD_BEEF, .n = 0x1234_5678 }, .{ .rd = 0x1234_5678 }),
    vec("bfi #31, #1 sets the top bit", .{ .hw1 = bfi, .hw2 = h2(0, 31, 31), .n = 1 }, .{ .rd = 0x8000_0000 }),
    vec("bfi #4, #1 copies only Rn[0]", .{ .hw1 = bfi, .hw2 = h2(0, 4, 4), .d = 0xFF, .n = 0xFFFF_FFFE }, .{ .rd = 0xEF }),
    vec("bfc r0, #8, #8", .{ .hw1 = bfc, .hw2 = h2(0, 8, 15), .d = 0xFFFF_FFFF }, .{ .rd = 0xFFFF_00FF }),
    vec("bfc #0, #32 clears the word", .{ .hw1 = bfc, .hw2 = h2(0, 0, 31), .d = 0xDEAD_BEEF }, .{ .rd = 0 }),
    vec("ubfx r12, lr, #4, #4", .{ .hw1 = 0xF3CE, .hw2 = h2(12, 4, 3), .n = 0xAB }, .{ .rd = 0xA }),
    vec("bfi r1, r1, #8, #8 reads Rn before writing", .{ .hw1 = bfi, .hw2 = h2(1, 8, 15), .n = 0x12 }, .{ .rd = 0x1212 }),
    vec("an extract past bit 31 is unclaimed", .{ .hw1 = ubfx, .hw2 = h2(0, 8, 31) }, none),
    vec("an insert with msb below lsb is unclaimed", .{ .hw1 = bfi, .hw2 = h2(0, 8, 7) }, none),
    vec("Rd of sp is unclaimed", .{ .hw1 = ubfx, .hw2 = h2(13, 0, 7) }, none),
    vec("Rd of pc is unclaimed", .{ .hw1 = bfi, .hw2 = h2(15, 0, 7) }, none),
    vec("Rn of sp is unclaimed", .{ .hw1 = 0xF34D, .hw2 = h2(0, 0, 7) }, none),
    vec("sbfx from pc is unclaimed", .{ .hw1 = 0xF34F, .hw2 = h2(0, 0, 7) }, none),
    vec("a set hw2[15] is unclaimed", .{ .hw1 = ubfx, .hw2 = h2(0, 0, 7) | 0x8000 }, none),
    vec("a set hw2[5] is unclaimed", .{ .hw1 = ubfx, .hw2 = h2(0, 0, 7) | 0x20 }, none),
    vec("ssat belongs to saturate", .{ .hw1 = 0xF301, .hw2 = h2(0, 0, 7) }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = ubfx, .hw2 = h2(0, 8, 7), .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
