//! Conformance vectors for the decode group `sel` (RA8EMU-280): SEL (T1).
//! Expected values are worked from the Arm ARM (DDI0553): byte i of Rd is
//! byte i of Rn when APSR.GE[i] is set and byte i of Rm when it is clear;
//! NZCV and GE are left as they were. SP or PC in any register, a wrong
//! hw2[15:12] or hw2[7:4] and the misc_wide and parallel neighbours are left
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

/// Whether the group claims the encoding, then Rd, NZCV and GE after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
    ge: u4 = 0,
};

const V = vector.Vector(In, Out);
const group = "sel";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 carries Rd r0 and Rm r2.
const sel = 0xFAA1;
const plain = 0xF082;
const n: u32 = 0x1122_3344;
const m: u32 = 0xAABB_CCDD;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn pick(name: []const u8, ge: u4, rd: u32) V {
    return vec(name, .{ .hw1 = sel, .hw2 = plain, .ge = ge, .n = n, .m = m }, .{ .rd = rd, .ge = ge });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    pick("GE 0000 takes every byte from Rm", 0x0, 0xAABB_CCDD),
    pick("GE 1111 takes every byte from Rn", 0xF, 0x1122_3344),
    pick("GE 0001 takes byte 0 from Rn", 0x1, 0xAABB_CC44),
    pick("GE 0010 takes byte 1 from Rn", 0x2, 0xAABB_33DD),
    pick("GE 0100 takes byte 2 from Rn", 0x4, 0xAA22_CCDD),
    pick("GE 1000 takes byte 3 from Rn", 0x8, 0x11BB_CCDD),
    pick("GE 0101 alternates", 0x5, 0xAA22_CC44),
    pick("GE 1010 alternates the other way", 0xA, 0x11BB_33DD),
    pick("GE 0011 takes the low halfword from Rn", 0x3, 0xAABB_3344),
    pick("GE 1100 takes the high halfword from Rn", 0xC, 0x1122_CCDD),
    vec("sel r12, lr, r4", .{ .hw1 = 0xFAAE, .hw2 = 0xFC84, .ge = 0x6, .n = 0x0102_0304, .m = 0x0A0B_0C0D }, .{ .rd = 0x0A02_030D, .ge = 0x6 }),
    vec("sel r1, r1, r1 keeps the value", .{ .hw1 = sel, .hw2 = 0xF181, .ge = 0x5, .n = n, .m = n }, .{ .rd = n, .ge = 0x5 }),
    bad("Rd of sp is unclaimed", sel, 0xFD82),
    bad("Rd of pc is unclaimed", sel, 0xFF82),
    bad("Rn of sp is unclaimed", 0xFAAD, plain),
    bad("Rn of pc is unclaimed", 0xFAAF, plain),
    bad("Rm of sp is unclaimed", sel, 0xF08D),
    bad("Rm of pc is unclaimed", sel, 0xF08F),
    bad("a wrong hw2[7:4] is unclaimed", sel, 0xF092),
    bad("a wrong hw2[15:12] is unclaimed", sel, 0xE082),
    bad("rev belongs to misc_wide", 0xFA91, 0xF081),
    bad("uadd8 belongs to parallel", 0xFA81, 0xF042),
    vec("the 16-bit space is unclaimed", .{ .hw1 = sel, .hw2 = plain, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
