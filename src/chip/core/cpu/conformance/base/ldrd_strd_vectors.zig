//! Conformance vectors for the decode group `ldrd_strd` (RA8EMU-278): LDRD
//! and STRD (T1) with an immediate offset. Expected values are worked from
//! the Arm ARM (DDI0553): two words at Rn +/- imm8*4 (Rn itself when
//! post-indexed), Rt at the lower address and Rt2 above it, writeback
//! leaving Rn at the offset address, a word-unaligned address raising an
//! alignment fault (MemA) with nothing changed, and an access outside
//! memory faulting with the registers kept. P = 0 with W = 0, Rn = PC, SP
//! or PC as Rt or Rt2, LDRD with Rt = Rt2, writeback with Rn equal to Rt or
//! Rt2, the load/store-multiple space and the 16-bit space are unclaimed.
const vector = @import("../vector.zig");

/// Rn = r0 holds In.rn; Rt = r2 and Rt2 = r3 hold `src_lo` and `src_hi`;
/// the doubleword placed at `at` is `lo` then `hi`.
pub const base: u32 = 0x2000_0200;
pub const src_lo: u32 = 0x1122_3344;
pub const src_hi: u32 = 0x5566_7788;
pub const lo: u32 = 0x8765_C3A9;
pub const hi: u32 = 0x0BAD_F00D;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    rn: u32 = base,
    at: u32 = 0,
    /// The doubleword read back after the instruction (0 for none).
    probe: u32 = 0,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, unaligned, other };

/// Whether the group claims the encoding, how it ended, r2, r3 and r0
/// afterwards, and the probed doubleword.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    r2: u32 = src_lo,
    r3: u32 = src_hi,
    rn: u32 = base,
    mem_lo: u32 = 0,
    mem_hi: u32 = 0,
};

const V = vector.Vector(In, Out);
const group = "ldrd_strd";
const none: Out = .{ .claimed = false, .r2 = 0, .r3 = 0, .rn = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ld(name: []const u8, hw1: u16, hw2: u16, at: u32, rn: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .at = at }, .{ .r2 = lo, .r3 = hi, .rn = rn });
}

fn st(name: []const u8, hw1: u16, hw2: u16, probe: u32, rn: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .probe = probe }, .{ .rn = rn, .mem_lo = src_lo, .mem_hi = src_hi });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = loads ++ stores ++ unclaimed;

const loads = [_]V{
    ld("ldrd r2, r3, [r0, #8]", 0xE9D0, 0x2302, 0x2000_0208, base),
    ld("ldrd r2, r3, [r0]", 0xE9D0, 0x2300, 0x2000_0200, base),
    ld("ldrd r2, r3, [r0, #-8]", 0xE950, 0x2302, 0x2000_01F8, base),
    ld("ldrd r2, r3, [r0, #8]! writes back", 0xE9F0, 0x2302, 0x2000_0208, 0x2000_0208),
    ld("ldrd r2, r3, [r0, #-508]! writes back", 0xE970, 0x237F, 0x2000_0004, 0x2000_0004),
    ld("ldrd r2, r3, [r0], #4 reads at rn", 0xE8F0, 0x2301, 0x2000_0200, 0x2000_0204),
    ld("ldrd r2, r3, [r0], #-8", 0xE870, 0x2302, 0x2000_0200, 0x2000_01F8),
    vec("ldrd r3, r2 puts rt at the lower address", .{ .hw1 = 0xE9D0, .hw2 = 0x3202, .at = 0x2000_0208 }, .{ .r2 = hi, .r3 = lo }),
    vec("ldrd at a halfword address is an alignment fault", .{ .hw1 = 0xE9F0, .hw2 = 0x2300, .rn = 0x2000_0202, .at = 0x2000_0200 }, .{ .fault = .unaligned, .rn = 0x2000_0202 }),
    vec("ldrd past RAM faults and keeps the registers", .{ .hw1 = 0xE9F0, .hw2 = 0x23FF }, .{ .fault = .unmapped }),
};

const stores = [_]V{
    st("strd r2, r3, [r0, #8]", 0xE9C0, 0x2302, 0x2000_0208, base),
    st("strd r2, r3, [r0, #-4]", 0xE940, 0x2301, 0x2000_01FC, base),
    st("strd r2, r3, [r0, #8]! writes back", 0xE9E0, 0x2302, 0x2000_0208, 0x2000_0208),
    st("strd r2, r3, [r0, #-8]! writes back", 0xE960, 0x2302, 0x2000_01F8, 0x2000_01F8),
    st("strd r2, r3, [r0], #16 writes at rn", 0xE8E0, 0x2304, 0x2000_0200, 0x2000_0210),
    st("strd r2, r3, [r0], #-4", 0xE860, 0x2301, 0x2000_0200, 0x2000_01FC),
    vec("strd r3, r2 puts rt at the lower address", .{ .hw1 = 0xE9C0, .hw2 = 0x3202, .probe = 0x2000_0208 }, .{ .mem_lo = src_hi, .mem_hi = src_lo }),
    vec("strd r2, r2 stores rt twice", .{ .hw1 = 0xE9C0, .hw2 = 0x2202, .probe = 0x2000_0208 }, .{ .mem_lo = src_lo, .mem_hi = src_lo }),
    vec("strd r0, r3, [r0, #8] stores the base", .{ .hw1 = 0xE9C0, .hw2 = 0x0302, .probe = 0x2000_0208 }, .{ .mem_lo = base, .mem_hi = src_hi }),
    vec("strd at a halfword address is an alignment fault", .{ .hw1 = 0xE9E0, .hw2 = 0x2300, .rn = 0x2000_0202, .probe = 0x2000_0200 }, .{ .fault = .unaligned, .rn = 0x2000_0202 }),
    vec("strd past RAM faults and keeps rn", .{ .hw1 = 0xE9E0, .hw2 = 0x23FF }, .{ .fault = .unmapped }),
};

const unclaimed = [_]V{
    bad("P = 0 W = 0 with U set is unclaimed", 0xE8D0, 0x2302),
    bad("P = 0 W = 0 with U clear is unclaimed", 0xE850, 0x2302),
    bad("ldrd with rn = pc is the literal form", 0xE9DF, 0x2302),
    bad("strd with rn = pc is unclaimed", 0xE9CF, 0x2302),
    bad("rt = sp is unclaimed", 0xE9D0, 0xD302),
    bad("rt2 = pc is unclaimed", 0xE9D0, 0x2F02),
    bad("strd of pc is unclaimed", 0xE9C0, 0xF302),
    bad("ldrd with rt = rt2 is unclaimed", 0xE9D0, 0x2202),
    bad("writeback with rn = rt is unclaimed", 0xE9F0, 0x0302),
    bad("writeback with rn = rt2 is unclaimed", 0xE9F0, 0x2002),
    bad("hw1 bit 6 clear is the multiple space", 0xE990, 0x2302),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xE9D0, .hw2 = 0x2302, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
