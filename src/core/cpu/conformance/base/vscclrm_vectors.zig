//! Conformance vectors for the decode group `vscclrm` (RA8EMU-278).
//! Expected values are worked from the Arm ARM (DDI0553) VSCCLRM
//! pseudocode: T2 (singles) clears imm8 registers from Vd:D, T1 (doubles)
//! clears imm8/2 registers from D:Vd, and VPR is zeroed with them, an
//! empty list clearing VPR alone. With FPCCR.ASPEN set and CONTROL.SFPA
//! clear there is no Secure FP context and the instruction does nothing;
//! otherwise ExecuteFPCheck runs first, so SFPA with FPCA clear creates
//! the context. Non-secure state is UNDEFINED, before the NOP case.
//! `cleared` is the mask of S registers that read zero after
//! a bank where every register starts non-zero. A run past S31 or D15, an
//! odd imm8 in the double form, a base other than PC, W set, hw2[11:9]
//! not 101 and the 16-bit space are left unclaimed.
const vector = @import("../vector.zig");

pub const vpr_reset: u32 = 0x00AB_1234;
pub const fpca: u32 = 1 << 2;
pub const sfpa: u32 = 1 << 3;

pub const In = struct {
    hw1: u16 = 0xEC9F,
    hw2: u16,
    size: u8 = 4,
    aspen: u1 = 1,
    control: u32 = fpca | sfpa,
    secure: bool = true,
};

pub const Fault = enum { none, undefined_instr };

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    cleared: u32,
    vpr: u32 = 0,
    control: u32 = fpca | sfpa,
};

const V = vector.Vector(In, Out);
const group = "vscclrm";
pub const none: Out = .{ .claimed = false, .cleared = 0, .vpr = 0, .control = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = singles ++ doubles ++ context ++ unclaimed;

const singles = [_]V{
    vec("vscclrm {s0-s3, vpr}", .{ .hw2 = 0x0A04 }, .{ .cleared = 0x0000_000F }),
    vec("vscclrm {s1-s2, vpr} takes d as the low bit", .{ .hw1 = 0xECDF, .hw2 = 0x0A02 }, .{ .cleared = 0x0000_0006 }),
    vec("vscclrm {s4, vpr}", .{ .hw2 = 0x2A01 }, .{ .cleared = 0x0000_0010 }),
    vec("vscclrm {s0-s31, vpr}", .{ .hw2 = 0x0A20 }, .{ .cleared = 0xFFFF_FFFF }),
    vec("vscclrm {s31, vpr}", .{ .hw1 = 0xECDF, .hw2 = 0xFA01 }, .{ .cleared = 0x8000_0000 }),
    vec("vscclrm {vpr} clears vpr alone", .{ .hw2 = 0x0A00 }, .{ .cleared = 0 }),
};

const doubles = [_]V{
    vec("vscclrm {d0-d1, vpr}", .{ .hw2 = 0x0B04 }, .{ .cleared = 0x0000_000F }),
    vec("vscclrm {d3, vpr}", .{ .hw2 = 0x3B02 }, .{ .cleared = 0x0000_00C0 }),
    vec("vscclrm {d0-d15, vpr}", .{ .hw2 = 0x0B20 }, .{ .cleared = 0xFFFF_FFFF }),
    vec("vscclrm {d15, vpr}", .{ .hw2 = 0xFB02 }, .{ .cleared = 0xC000_0000 }),
    vec("vscclrm {d0, vpr} with an empty pair list clears vpr", .{ .hw2 = 0x0B00 }, .{ .cleared = 0 }),
};

const context = [_]V{
    vec("no secure fp context is a nop", .{ .hw2 = 0x0A04, .control = 0 }, .{ .cleared = 0, .vpr = vpr_reset, .control = 0 }),
    vec("sfpa without fpca creates the context then clears", .{ .hw2 = 0x0A04, .control = sfpa }, .{ .cleared = 0x0000_000F }),
    vec("non-secure is undefined", .{ .hw2 = 0x0A04, .secure = false }, .{ .fault = .undefined_instr, .cleared = 0, .vpr = vpr_reset }),
    vec("non-secure with no fp context is still undefined", .{ .hw2 = 0x0A04, .secure = false, .control = 0 }, .{ .fault = .undefined_instr, .cleared = 0, .vpr = vpr_reset, .control = 0 }),
    vec("aspen clear always clears", .{ .hw2 = 0x0A04, .aspen = 0, .control = 0 }, .{ .cleared = 0x0000_000F, .control = 0 }),
};

const unclaimed = [_]V{
    bad("a double run from d16 is unclaimed", 0xECDF, 0x0B02),
    bad("an odd imm8 in the double form is unclaimed", 0xEC9F, 0x0B03),
    bad("a single run past s31 is unclaimed", 0xECDF, 0xFA02),
    bad("a double run past d15 is unclaimed", 0xEC9F, 0xFB04),
    bad("a base other than pc is unclaimed", 0xEC9E, 0x0A04),
    bad("w set is unclaimed", 0xECBF, 0x0A04),
    bad("hw2[11:9] = 110 is unclaimed", 0xEC9F, 0x0C04),
    vec("the 16-bit space is unclaimed", .{ .hw2 = 0x0A04, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
