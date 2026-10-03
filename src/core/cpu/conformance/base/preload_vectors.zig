//! Conformance vectors for the decode group `preload` (RA8EMU-278): PLD,
//! PLDW and PLI in the immediate (T1 imm12, T2 negative imm8), literal and
//! register forms. The Arm ARM (DDI0553) makes a preload a hint with no
//! architectural effect, so each claimed vector checks the core state
//! survives and that a preload of unmapped memory raises nothing. PLI or a
//! literal PLD with W set, a register offset of SP or PC, the other hw2
//! forms, Rt other than PC, word or store encodings and the 16-bit space are
//! left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N, C and Q), which must survive.
pub const flags: u32 = 0xA800_0000;
/// Rn = r0 points nowhere; Rm = r1 holds a small index.
pub const base: u32 = 0x1000_0000;
pub const index: u32 = 4;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
};

/// Whether the group claims the encoding, then r0, r1 and NZCVQ after.
pub const Out = struct {
    claimed: bool = true,
    r0: u32 = base,
    r1: u32 = index,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "preload";
const none: Out = .{ .claimed = false, .r0 = 0, .r1 = 0, .flags = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ok(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, .{});
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    ok("pld [r0, #16] of unmapped memory changes nothing", 0xF890, 0xF010),
    ok("pld [r0, #4095]", 0xF890, 0xFFFF),
    ok("pldw [r0, #16]", 0xF8B0, 0xF010),
    ok("pli [r0, #16]", 0xF990, 0xF010),
    ok("pld [r0, #-8]", 0xF810, 0xFC08),
    ok("pldw [r0, #-255]", 0xF830, 0xFCFF),
    ok("pli [r0, #-8]", 0xF910, 0xFC08),
    ok("pld literal forwards", 0xF89F, 0xF010),
    ok("pld literal backwards", 0xF81F, 0xF010),
    ok("pli literal forwards", 0xF99F, 0xF010),
    ok("pli literal backwards", 0xF91F, 0xF010),
    ok("pld [r0, r1, lsl #2]", 0xF810, 0xF021),
    ok("pld [r0, r1]", 0xF810, 0xF001),
    ok("pldw [r0, r1]", 0xF830, 0xF001),
    ok("pli [r0, r1, lsl #3]", 0xF910, 0xF031),
    ok("pld [r12, #0]", 0xF89C, 0xF000),
    bad("pli with W set is unclaimed", 0xF9B0, 0xF010),
    bad("pldw literal is unclaimed", 0xF8BF, 0xF010),
    bad("pli with W and U clear is unclaimed", 0xF930, 0xFC08),
    bad("a register offset of sp is unclaimed", 0xF810, 0xF00D),
    bad("a register offset of pc is unclaimed", 0xF810, 0xF00F),
    bad("hw2[11:8] of 0001 is unclaimed", 0xF810, 0xF100),
    bad("hw2[6] set in the register form is unclaimed", 0xF810, 0xF041),
    bad("a T4 post-indexed form is unclaimed", 0xF810, 0xF908),
    bad("a T2 form with W set is unclaimed", 0xF810, 0xFD08),
    bad("Rt other than pc is a load, not a preload", 0xF890, 0xE010),
    bad("a word load with Rt = pc is unclaimed", 0xF8D0, 0xF010),
    bad("a byte store is unclaimed", 0xF880, 0xF010),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF890, .hw2 = 0xF010, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
