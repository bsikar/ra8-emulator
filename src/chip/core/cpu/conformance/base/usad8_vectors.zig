//! Conformance vectors for the decode group `usad8` (RA8EMU-280): USAD8 and
//! USADA8 (T1). Expected values are worked from the Arm ARM (DDI0553): Rd is
//! the sum of the four unsigned absolute byte differences of Rn and Rm, plus
//! Ra for USADA8 (Ra = 1111 selects USAD8), modulo 2^32; no flags change. SP
//! or PC in Rd, Rn or Rm, Ra = SP, a non-zero hw2[7:4] and the neighbouring
//! multiply rows are left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Ra, Rn, then Rm before the instruction, written in that order.
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
const group = "usad8";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; usad8 r0, r1, r2 and usada8 r0, r1, r2, r3.
const hw1 = 0xFB71;
const usad8 = 0xF002;
const usada8 = 0x3002;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn sad(name: []const u8, n: u32, m: u32, rd: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = usad8, .n = n, .m = m }, .{ .rd = rd });
}

fn sada(name: []const u8, a: u32, n: u32, m: u32, rd: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = usada8, .a = a, .n = n, .m = m }, .{ .rd = rd });
}

fn bad(name: []const u8, h1: u16, h2: u16) V {
    return vec(name, .{ .hw1 = h1, .hw2 = h2 }, none);
}

pub const all = [_]V{
    sad("equal operands give zero", 0x1234_5678, 0x1234_5678, 0),
    sad("byte differences either way are absolute", 0x0102_0304, 0x0403_0201, 8),
    sad("full-range bytes in both directions", 0xFF00_FF00, 0x00FF_00FF, 0x3FC),
    sad("Rn larger in every byte", 0x1020_3040, 0, 0xA0),
    sad("Rm larger in every byte", 0, 0x1020_3040, 0xA0),
    sad("bytes compare unsigned, not signed", 0x80, 0x7F, 1),
    sada("usada8 adds Ra", 100, 0x0102_0304, 0x0403_0201, 108),
    sada("usada8 keeps Ra for equal operands", 0x1234_5678, 0x55, 0x55, 0x1234_5678),
    sada("usada8 wraps modulo 2^32", 0xFFFF_FFFF, 1, 0, 0),
    vec("usada8 Ra may be Rd", .{ .hw1 = hw1, .hw2 = 0x0002, .a = 5, .n = 2, .m = 0 }, .{ .rd = 7 }),
    vec("usad8 r12, lr, r4", .{ .hw1 = 0xFB7E, .hw2 = 0xFC04, .n = 0x0A0A_0A0A, .m = 0x0505_0505 }, .{ .rd = 20 }),
    vec("usad8 r0, r1, r1 is zero", .{ .hw1 = hw1, .hw2 = 0xF001, .n = 0x1234_5678, .m = 0x1234_5678 }, .{ .rd = 0 }),
    bad("Rd of sp is unclaimed", hw1, 0xFD02),
    bad("Rd of pc is unclaimed", hw1, 0xFF02),
    bad("Rn of sp is unclaimed", 0xFB7D, usad8),
    bad("Rn of pc is unclaimed", 0xFB7F, usad8),
    bad("Rm of sp is unclaimed", hw1, 0xF00D),
    bad("Rm of pc is unclaimed", hw1, 0xF00F),
    bad("Ra of sp is unclaimed", hw1, 0xD002),
    bad("a non-zero hw2[7:4] is unclaimed", hw1, 0xF012),
    bad("smmul (0xFB50) is not usad8", 0xFB51, usad8),
    vec("the 16-bit space is unclaimed", .{ .hw1 = hw1, .hw2 = usad8, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
