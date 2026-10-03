//! Conformance vectors for the decode group `clrm` (RA8EMU-278): CLRM (T1),
//! Armv8.1-M. Expected values are worked from the Arm ARM (DDI0553): every
//! listed register is zeroed and nothing else changes; hw2[14] zeroes LR;
//! hw2[15] (APSR) clears N, Z, C, V, Q and GE[3:0] but keeps the Thumb bit
//! and the exception number. An empty list and a list naming SP are
//! UNPREDICTABLE and left unclaimed, as are LDM forms beside it and the
//! 16-bit space.
const vector = @import("../vector.zig");

/// Before each run Rn holds `fill + n`, LR holds `lr_in`, and SP holds
/// `sp_in`, so a zero after means the instruction cleared it.
pub const fill: u32 = 0x5A00_0100;
pub const lr_in: u32 = 0xFFFF_FFF9;
pub const sp_in: u32 = 0x2000_0300;
/// Thumb, N Z C V Q and GE[3:0] all set.
pub const xpsr_in: u32 = 0x01 << 24 | 0xF800_0000 | 0xF << 16;
pub const thumb: u32 = 1 << 24;

pub const In = struct {
    hw1: u16 = 0xE89F,
    hw2: u16,
    size: u8 = 4,
    xpsr: u32 = xpsr_in,
};

/// Whether the group claims the encoding, which of R0 to R12 (bits 0 to
/// 12) and LR (bit 14) read zero after, whether every other register kept
/// its value, and xPSR after.
pub const Out = struct {
    claimed: bool = true,
    zeroed: u16 = 0,
    kept: bool = true,
    xpsr: u32 = xpsr_in,
};

const V = vector.Vector(In, Out);
const group = "clrm";
const none: Out = .{ .claimed = false, .kept = false, .xpsr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// A list without APSR: exactly the named general registers go to zero.
fn regs(name: []const u8, list: u16) V {
    return vec(name, .{ .hw2 = list }, .{ .zeroed = list });
}

/// A list with APSR: the named registers go to zero and xPSR keeps only
/// the Thumb bit and the exception number.
fn apsr(name: []const u8, list: u16, xpsr: u32, after: u32) V {
    return vec(name, .{ .hw2 = list, .xpsr = xpsr }, .{ .zeroed = list & 0x5FFF, .xpsr = after });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = lists ++ flags ++ unclaimed;

const lists = [_]V{
    regs("clrm {r0}", 0x0001),
    regs("clrm {r1}", 0x0002),
    regs("clrm {r7}", 0x0080),
    regs("clrm {r12}", 0x1000),
    regs("clrm {r3, r7}", 0x0088),
    regs("clrm {r0-r3}", 0x000F),
    regs("clrm {r4-r11}", 0x0FF0),
    regs("clrm {r0-r12}", 0x1FFF),
    regs("clrm {lr}", 0x4000),
    regs("clrm {r0, lr}", 0x4001),
    regs("clrm {r0-r12, lr}", 0x5FFF),
};

const flags = [_]V{
    apsr("clrm {apsr} clears nzcvq and ge", 0x8000, xpsr_in, thumb),
    apsr("clrm {apsr} keeps the exception number", 0x8000, xpsr_in | 3, thumb | 3),
    apsr("clrm {apsr} with only q set", 0x8000, thumb | 1 << 27, thumb),
    apsr("clrm {apsr} with only ge set", 0x8000, thumb | 0x5 << 16, thumb),
    apsr("clrm {apsr} with flags already clear", 0x8000, thumb, thumb),
    apsr("clrm {r0, r2, r4, lr, apsr}", 0xC015, xpsr_in, thumb),
    apsr("clrm {r1-r12, lr, apsr}", 0xDFFE, xpsr_in, thumb),
    apsr("clrm {r0-r12, lr, apsr}", 0xDFFF, xpsr_in | 11, thumb | 11),
};

const unclaimed = [_]V{
    bad("an empty list is unclaimed", 0xE89F, 0x0000),
    bad("sp in the list is unclaimed", 0xE89F, 0x2000),
    bad("sp with r0 is unclaimed", 0xE89F, 0x2001),
    bad("sp with apsr is unclaimed", 0xE89F, 0xA000),
    bad("ldm pc! is not clrm", 0xE8BF, 0x0001),
    bad("ldm lr is not clrm", 0xE89E, 0x0001),
    bad("ldmdb pc is not clrm", 0xE91F, 0x0001),
    vec("the 16-bit space is unclaimed", .{ .hw2 = 0x0001, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
