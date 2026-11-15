//! Conformance vectors for the decode group `mve_float_vcmul`
//! (RA8EMU-278): VCMUL on F32 and F16 lane pairs, rotations 0, 90, 180 and
//! 270. Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! (re, im) is (n.re*m.re, n.re*m.im) at 0, (n.im*-m.im, n.im*m.re) at
//! 90, (n.re*-m.re, n.re*-m.im) at 180 and (n.im*m.im, n.im*-m.re) at 270,
//! each one FPMul under StandardFPSCRValue (round to nearest even, DN and
//! FZ set, FZ16 kept). An F32 denormal operand reads as zero with IDC and a
//! tiny F32 product flushes to zero with UFC; with FZ16 an F16 subnormal
//! operand reads as zero with no flag. NaNs and infinity times zero give
//! the default NaN (IOC if signalling or invalid); overflow gives infinity
//! with OFC and IXC. A pair runs when any of its bytes is predicated (VPT,
//! loop tail, EPSR.ECI), bytes merge under the mask, and each half's
//! flags count only when that half's first byte is. Qd, Qn and Qm are
//! written in that order; Qd never equals Qn or Qm here (UNPREDICTABLE at
//! F32). Q8 and above, flipped fixed bits and the 16-bit space are
//! unclaimed.
const defs = @import("vcmul_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = rotations ++ predicated ++ unclaimed;

const rotations_01 = @import("vcmul_rotations_01.zig");
const rotations_02 = @import("vcmul_rotations_02.zig");

const rotations = rotations_01.values ++
    rotations_02.values;

const predicated_01 = @import("vcmul_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xFE33, .hw2 = 0x0E04 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFE72, .hw2 = 0x0E04 }, none),
    vec("hw1 bit 5 clear is unclaimed", .{ .hw1 = 0xFE12, .hw2 = 0x0E04 }, none),
    vec("hw1 bit 8 set is unclaimed", .{ .hw1 = 0xFF32, .hw2 = 0x0E04 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E84 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E24 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E14 }, none),
    vec("hw2 bit 6 set is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E44 }, none),
    vec("hw2[11:8] other than 1110 is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0F04 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
