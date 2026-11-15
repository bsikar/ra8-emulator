//! Conformance vectors for the decode group `fp.convert` (RA8EMU-278): the
//! FPv5 VCVT family (T1). Expected values are worked from the Arm ARM
//! (DDI0553): single <-> double rounds by FPSCR and moves a signalling
//! NaN's payload to the top, quieted, with IOC; VCVT to S32/U32 truncates
//! and VCVTR uses RMode (ties to even), saturating with IOC on NaN or out
//! of range; S32/U32 to float rounds by RMode; fixed point converts Sd/Dd
//! in place with fbits = width - imm5, results extended to the register;
//! VCVTB/VCVTT read or write the bottom/top half lane, keeping the other
//! lane. opc2 0111 with o clear, D16 and up, imm5 wider than the integer,
//! hw2[6] clear and the 16-bit space are left unclaimed.
const defs = @import("convert_types.zig");

const bad = defs.bad;
const ixc = defs.ixc;
const raised = defs.raised;
const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const fpscr_reset = defs.fpscr_reset;
pub const dst_reset = defs.dst_reset;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = precision ++ to_int ++ from_int ++ fixed ++ half ++ unclaimed;

const precision_01 = @import("convert_precision_01.zig");

const precision = precision_01.values;

const to_int_01 = @import("convert_to_int_01.zig");

const to_int = to_int_01.values;

const from_int = [_]V{
    vec("vcvt.f32.s32 -1", .{ .hw1 = 0xEEB8, .hw2 = 0x0AE0, .src = 0xFFFF_FFFF }, .{ .dst = 0xBF80_0000 }),
    vec(
        "vcvt.f32.u32 0xffffffff rounds up",
        .{ .hw1 = 0xEEB8, .hw2 = 0x0A60, .src = 0xFFFF_FFFF },
        .{ .dst = 0x4F80_0000, .fpscr = raised(ixc) },
    ),
    vec(
        "vcvt.f32.s32 2^24 + 1 rounds to even",
        .{ .hw1 = 0xEEB8, .hw2 = 0x0AE0, .src = 0x0100_0001 },
        .{ .dst = 0x4B80_0000, .fpscr = raised(ixc) },
    ),
    vec(
        "vcvt.f64.s32 d0, s1 -1",
        .{ .hw1 = 0xEEB8, .hw2 = 0x0BE0, .src = 0xFFFF_FFFF, .dst_wide = true },
        .{ .dst = 0xBFF0_0000_0000_0000 },
    ),
};

const fixed_01 = @import("convert_fixed_01.zig");

const fixed = fixed_01.values;

const half_01 = @import("convert_half_01.zig");

const half = half_01.values;

const unclaimed = [_]V{
    bad("opc2 0111 with o clear is unclaimed", 0xEEB7, 0x0A41),
    bad("vcvt.f64.f32 d16, s2 is unclaimed", 0xEEF7, 0x0AC1),
    bad("vcvt.f32.f64 s0, d17 is unclaimed", 0xEEB7, 0x0BE1),
    bad("16-bit fixed with imm5 17 is unclaimed", 0xEEBE, 0x0A68),
    bad("opc2 0100 is not this group", 0xEEB4, 0x0A60),
    bad("hw2[6] clear is unclaimed", 0xEEBD, 0x0A81),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
