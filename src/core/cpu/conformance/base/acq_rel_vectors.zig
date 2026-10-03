//! Conformance vectors for the decode group `acq_rel` (RA8EMU-278): LDA,
//! LDAB, LDAH, STL, STLB and STLH (T1). Expected values are worked from the
//! Arm ARM (DDI0553): the address is Rn with no offset, a load zero-extends,
//! a store writes only its own bytes, the acquire/release ordering changes
//! nothing on one core, and every form is MemA, so an unaligned word or
//! halfword faults with nothing changed. An access outside memory faults
//! with Rt kept. Size 11, SP or PC as Rt, PC as Rn, the fixed-ones fields
//! not all ones, the exclusive forms beside them and the 16-bit space are
//! left unclaimed.
const vector = @import("../vector.zig");

/// Rn = r0 holds In.rn; Rt = r1 holds `src`; the words at `base` and
/// `base + 4` hold `literal` (bytes A9 C3 65 87) and `next`.
pub const base: u32 = 0x2000_0200;
pub const src: u32 = 0x1122_3344;
pub const literal: u32 = 0x8765_C3A9;
pub const next: u32 = 0x0BAD_F00D;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    rn: u32 = base,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, unaligned, other };

/// Whether the group claims the encoding, how it ended, r1 and r0 after,
/// and the word at `base` after.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    rt: u32 = src,
    rn: u32 = base,
    mem: u32 = literal,
};

const V = vector.Vector(In, Out);
const group = "acq_rel";
const none: Out = .{ .claimed = false, .rt = 0, .rn = 0, .mem = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ld(name: []const u8, hw2: u16, rn: u32, rt: u32) V {
    return vec(name, .{ .hw1 = 0xE8D0, .hw2 = hw2, .rn = rn }, .{ .rt = rt, .rn = rn });
}

fn st(name: []const u8, hw2: u16, rn: u32, mem: u32) V {
    return vec(name, .{ .hw1 = 0xE8C0, .hw2 = hw2, .rn = rn }, .{ .rn = rn, .mem = mem });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = loads ++ stores ++ unclaimed;

const loads = [_]V{
    ld("lda r1, [r0]", 0x1FAF, base, literal),
    ld("lda r1, [r0] at the next word", 0x1FAF, base + 4, next),
    ld("ldab r1, [r0] zero-extends", 0x1F8F, base, 0xA9),
    ld("ldab r1, [r0] at an odd address", 0x1F8F, base + 1, 0xC3),
    ld("ldah r1, [r0] zero-extends", 0x1F9F, base, 0xC3A9),
    ld("ldah r1, [r0] reads the high half", 0x1F9F, base + 2, 0x8765),
    vec("lda r0, [r0] overwrites the base", .{ .hw1 = 0xE8D0, .hw2 = 0x0FAF }, .{ .rn = literal }),
    vec("lda at a halfword address faults", .{ .hw1 = 0xE8D0, .hw2 = 0x1FAF, .rn = base + 2 }, .{ .fault = .unaligned, .rn = base + 2 }),
    vec("ldah at an odd address faults", .{ .hw1 = 0xE8D0, .hw2 = 0x1F9F, .rn = base + 1 }, .{ .fault = .unaligned, .rn = base + 1 }),
    vec("lda past RAM faults and keeps rt", .{ .hw1 = 0xE8D0, .hw2 = 0x1FAF, .rn = 0x2000_0400 }, .{ .fault = .unmapped, .rn = 0x2000_0400 }),
};

const stores = [_]V{
    st("stl r1, [r0]", 0x1FAF, base, src),
    st("stlb r1, [r0] writes one byte", 0x1F8F, base, 0x8765_C344),
    st("stlb r1, [r0] at byte 3", 0x1F8F, base + 3, 0x4465_C3A9),
    st("stlh r1, [r0] writes one half", 0x1F9F, base, 0x8765_3344),
    st("stlh r1, [r0] at the high half", 0x1F9F, base + 2, 0x3344_C3A9),
    vec("stl at a halfword address faults and writes nothing", .{ .hw1 = 0xE8C0, .hw2 = 0x1FAF, .rn = base + 2 }, .{ .fault = .unaligned, .rn = base + 2 }),
    vec("stlh at an odd address faults", .{ .hw1 = 0xE8C0, .hw2 = 0x1F9F, .rn = base + 1 }, .{ .fault = .unaligned, .rn = base + 1 }),
    vec("stl past RAM faults", .{ .hw1 = 0xE8C0, .hw2 = 0x1FAF, .rn = 0x2000_0400 }, .{ .fault = .unmapped, .rn = 0x2000_0400 }),
};

const unclaimed = [_]V{
    bad("size 11 is unclaimed", 0xE8D0, 0x1FBF),
    bad("lda into sp is unclaimed", 0xE8D0, 0xDFAF),
    bad("lda into pc is unclaimed", 0xE8D0, 0xFFAF),
    bad("stl of pc is unclaimed", 0xE8C0, 0xFFAF),
    bad("rn = pc is unclaimed", 0xE8DF, 0x1FAF),
    bad("hw2[11:8] not all ones is unclaimed", 0xE8D0, 0x1EAF),
    bad("hw2[3:0] not all ones is unclaimed", 0xE8D0, 0x1FAE),
    bad("ldaex belongs to the exclusive group", 0xE8D0, 0x1FEF),
    bad("stlex belongs to the exclusive group", 0xE8C0, 0x1FE2),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xE8D0, .hw2 = 0x1FAF, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
