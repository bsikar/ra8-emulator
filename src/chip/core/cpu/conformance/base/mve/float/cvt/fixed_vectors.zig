//! Conformance vectors for the decode group `mve_float_cvt_fixed`
//! (RA8EMU-278): VCVT between F32 and 32-bit fixed point (1 to 32
//! fraction bits) and between F16 and 16-bit fixed point (1 to 16), both
//! ways, signed and unsigned. Expected values are worked from the Arm ARM
//! (DDI0553) FPToFixed and FixedToFP pseudocode under StandardFPSCRValue.
//! Float to fixed scales by 2^fbits and rounds toward zero; a NaN gives 0
//! with IOC, an infinity or out-of-range value saturates with IOC and no
//! IXC, an inexact result raises IXC, an F32 denormal reads as zero with
//! IDC, and with FZ16 an F16 subnormal reads as zero with no flag. Fixed to
//! float divides by 2^fbits and rounds to nearest even with IXC; an F16
//! result below the normal range is a subnormal, or with FZ16 a signed
//! zero with UFC. A lane runs when any byte is predicated (VPT, loop tail,
//! EPSR.ECI), bytes merge under the mask, and its flags count only when
//! its first byte is. Qd is written before Qm. Q8 and above, the imm6 bits
//! each size fixes, flipped fixed bits and the 16-bit space are unclaimed.
const defs = @import("fixed_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = to_fixed ++ from_fixed ++ predicated ++ unclaimed;

const to_fixed_01 = @import("fixed_to_fixed_01.zig");
const to_fixed_02 = @import("fixed_to_fixed_02.zig");

const to_fixed = to_fixed_01.values ++
    to_fixed_02.values;

const from_fixed_01 = @import("fixed_from_fixed_01.zig");
const from_fixed_02 = @import("fixed_from_fixed_02.zig");

const from_fixed = from_fixed_01.values ++
    from_fixed_02.values;

const predicated_01 = @import("fixed_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D51 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D70 }, none),
    vec("hw2 bit 4 clear is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D40 }, none),
    vec("hw2 bit 6 clear is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D10 }, none),
    vec("hw2 bit 7 set is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0DD0 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x1D50 }, none),
    vec("hw2 bit 10 clear is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0950 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEFF0, .hw2 = 0x0D50 }, none),
    vec("f16 with imm6<4> clear is unclaimed", .{ .hw1 = 0xEFA8, .hw2 = 0x0D50 }, none),
    vec("f32 with imm6<5> clear is unclaimed", .{ .hw1 = 0xEF90, .hw2 = 0x0F50 }, none),
    vec("hw1 bit 7 clear is unclaimed", .{ .hw1 = 0xEF30, .hw2 = 0x0D50 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D50, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
