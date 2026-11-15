//! Conformance vectors for the decode group `mve_float_vcmla`
//! (RA8EMU-278): VCMLA on F32 and F16 lane pairs, rotations 0, 90, 180 and
//! 270. Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! Qd (re, im) gains (n.re*m.re, n.re*m.im) at 0, (n.im*-m.im, n.im*m.re)
//! at 90, (n.re*-m.re, n.re*-m.im) at 180 and (n.im*m.im, n.im*-m.re) at
//! 270, each one FPMulAdd (a single rounding) under StandardFPSCRValue
//! (round to nearest even, DN and FZ set, FZ16 kept). An F32 denormal
//! operand reads as zero with IDC and a tiny F32 result flushes to zero
//! with UFC; with FZ16 an F16 subnormal reads as zero with no flag. Any NaN
//! gives the default NaN (IOC if signalling, or for infinity times zero
//! even with a quiet NaN addend); infinity times zero and opposite
//! infinities are invalid; an exact zero sum is +0; overflow gives
//! infinity with OFC and IXC. A pair runs when any of its bytes is predicated (VPT,
//! loop tail, EPSR.ECI), bytes merge under the mask, and each half's
//! flags count only when that half's first byte is. Qd, Qn and Qm are
//! written in that order; Qd never equals Qn or Qm here (UNPREDICTABLE at
//! F32). Q8 and above, flipped fixed bits and the 16-bit space are
//! unclaimed.
const defs = @import("vcmla_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = rotations ++ predicated ++ unclaimed;

const rotations_01 = @import("vcmla_rotations_01.zig");
const rotations_02 = @import("vcmla_rotations_02.zig");

const rotations = rotations_01.values ++
    rotations_02.values;

const predicated_01 = @import("vcmla_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xFC33, .hw2 = 0x0844 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFC72, .hw2 = 0x0844 }, none),
    vec("hw1 bit 9 set is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0844 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x1844 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x08C4 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0864 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0854 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0845 }, none),
    vec("hw2[11:8] other than 1000 is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0944 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
