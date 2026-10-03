//! Conformance vectors for the decode group `exclusive` (RA8EMU-278):
//! LDREX/B/H, STREX/B/H, CLREX and the acquire/release forms LDAEX/B/H and
//! STLEX/B/H. Expected values are worked from the Arm ARM (DDI0553): a
//! load-exclusive tags its address in the local monitor; a store-exclusive
//! writes only when the monitor holds its address, puts 0 (stored) or 1
//! (not stored) in Rd and clears the monitor either way; CLREX clears it;
//! every form is MemA, so an unaligned address faults before the monitor is
//! looked at. SP or PC as Rt or Rd, PC as Rn, a store whose Rd repeats Rt
//! or Rn, the fixed-ones fields not all ones, other op3 values and the
//! 16-bit space are left unclaimed.
const vector = @import("../vector.zig");

/// Rn = r0 holds In.rn; Rt = r1 holds `src`; Rd = r2 holds `fill`; the
/// words at `base` and `base + 4` hold `literal` (bytes A9 C3 65 87) and
/// `next`.
pub const base: u32 = 0x2000_0200;
pub const src: u32 = 0x1122_3344;
pub const fill: u32 = 0x5555_5555;
pub const literal: u32 = 0x8765_C3A9;
pub const next: u32 = 0x0BAD_F00D;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    rn: u32 = base,
    /// The monitor's tagged address before the instruction (0 for open).
    tag: u32 = 0,
    /// The word read back afterwards.
    probe: u32 = base,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, unaligned, other };

/// Whether the group claims the encoding, how it ended, Rt and Rd after,
/// the monitor's tag after (0 for open) and the probed word.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    rt: u32 = src,
    rd: u32 = fill,
    tag: u32 = 0,
    mem: u32 = literal,
};

const V = vector.Vector(In, Out);
const group = "exclusive";
const none: Out = .{ .claimed = false, .rt = 0, .rd = 0, .mem = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ld(name: []const u8, hw1: u16, hw2: u16, rt: u32, tag: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, .{ .rt = rt, .tag = tag });
}

/// A store with the monitor tagged at `base`: it writes and reports 0.
fn stored(name: []const u8, hw1: u16, hw2: u16, mem: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .tag = base }, .{ .rd = 0, .mem = mem });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = loads ++ stores ++ unclaimed;

const loads = [_]V{
    ld("ldrex r1, [r0] tags rn", 0xE850, 0x1F00, literal, base),
    ld("ldrex r1, [r0, #4] tags rn + 4", 0xE850, 0x1F01, next, base + 4),
    ld("ldrexb r1, [r0]", 0xE8D0, 0x1F4F, 0xA9, base),
    ld("ldrexh r1, [r0]", 0xE8D0, 0x1F5F, 0xC3A9, base),
    ld("ldaexb r1, [r0]", 0xE8D0, 0x1FCF, 0xA9, base),
    ld("ldaexh r1, [r0]", 0xE8D0, 0x1FDF, 0xC3A9, base),
    ld("ldaex r1, [r0]", 0xE8D0, 0x1FEF, literal, base),
    vec("ldrex moves a tag held elsewhere", .{ .hw1 = 0xE850, .hw2 = 0x1F00, .tag = 0x2000_0300 }, .{ .rt = literal, .tag = base }),
    vec("ldrexb at an odd address is aligned", .{ .hw1 = 0xE8D0, .hw2 = 0x1F4F, .rn = base + 1 }, .{ .rt = 0xC3, .tag = base + 1 }),
    vec("ldrex at a halfword address faults and tags nothing", .{ .hw1 = 0xE850, .hw2 = 0x1F00, .rn = base + 2 }, .{ .fault = .unaligned }),
    vec("ldrexh at an odd address faults", .{ .hw1 = 0xE8D0, .hw2 = 0x1F5F, .rn = base + 1 }, .{ .fault = .unaligned }),
    vec("ldrex past RAM faults and tags nothing", .{ .hw1 = 0xE850, .hw2 = 0x1F00, .rn = 0x2000_0400 }, .{ .fault = .unmapped }),
};

const stores = [_]V{
    stored("strex r2, r1, [r0] with the tag stores and reports 0", 0xE840, 0x1200, src),
    vec("strex r2, r1, [r0] with no tag reports 1", .{ .hw1 = 0xE840, .hw2 = 0x1200 }, .{ .rd = 1 }),
    vec("strex with the tag elsewhere reports 1 and clears it", .{ .hw1 = 0xE840, .hw2 = 0x1200, .tag = base + 4 }, .{ .rd = 1 }),
    vec("strex r2, r1, [r0, #4] with its tag", .{ .hw1 = 0xE840, .hw2 = 0x1201, .tag = base + 4, .probe = base + 4 }, .{ .rd = 0, .mem = src }),
    stored("strexb writes one byte", 0xE8C0, 0x1F42, 0x8765_C344),
    stored("strexh writes one half", 0xE8C0, 0x1F52, 0x8765_3344),
    stored("stlexb writes one byte", 0xE8C0, 0x1FC2, 0x8765_C344),
    stored("stlexh writes one half", 0xE8C0, 0x1FD2, 0x8765_3344),
    stored("stlex writes the word", 0xE8C0, 0x1FE2, src),
    vec("stlex with no tag reports 1", .{ .hw1 = 0xE8C0, .hw2 = 0x1FE2 }, .{ .rd = 1 }),
    vec("strex at a halfword address faults and keeps the tag", .{ .hw1 = 0xE840, .hw2 = 0x1200, .rn = base + 2, .tag = base + 2 }, .{ .fault = .unaligned, .tag = base + 2 }),
    vec("strex past RAM with no tag reports 1 and touches nothing", .{ .hw1 = 0xE840, .hw2 = 0x1200, .rn = 0x2000_0400 }, .{ .rd = 1 }),
    vec("clrex clears the tag", .{ .hw1 = 0xF3BF, .hw2 = 0x8F2F, .tag = base }, .{}),
    vec("clrex with no tag leaves it open", .{ .hw1 = 0xF3BF, .hw2 = 0x8F2F }, .{}),
};

const unclaimed = [_]V{
    bad("ldrex into sp is unclaimed", 0xE850, 0xDF00),
    bad("ldrex into pc is unclaimed", 0xE850, 0xFF00),
    bad("ldrex with rn = pc is unclaimed", 0xE85F, 0x1F00),
    bad("ldrex with hw2[11:8] not all ones is unclaimed", 0xE850, 0x1E00),
    bad("ldrexb with hw2[3:0] not all ones is unclaimed", 0xE8D0, 0x1F4E),
    bad("op3 0110 is unclaimed", 0xE8D0, 0x1F6F),
    bad("strex with rd = rt is unclaimed", 0xE840, 0x1100),
    bad("strex with rd = rn is unclaimed", 0xE840, 0x1000),
    bad("strex with rd = sp is unclaimed", 0xE840, 0x1D00),
    bad("strex with rd = pc is unclaimed", 0xE840, 0x1F00),
    bad("strexb with rd = rt is unclaimed", 0xE8C0, 0x1F41),
    bad("strexb with hw2[11:8] not all ones is unclaimed", 0xE8C0, 0x1E42),
    bad("a control-space neighbour of clrex is unclaimed", 0xF3BF, 0x8F2E),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xE850, .hw2 = 0x1F00, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
