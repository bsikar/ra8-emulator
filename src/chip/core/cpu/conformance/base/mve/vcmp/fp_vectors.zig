//! Conformance vectors for the decode group `mve_vcmp_fp` (RA8EMU-278): the
//! F32 and F16 VCMP and VPT forms, vector by vector and vector by scalar,
//! for EQ, NE, GE, LT, GT and LE. Expected values are worked from the Arm
//! ARM (DDI0553) pseudocode: FPCompareEQ, FPCompareGE or FPCompareGT under
//! StandardFPSCRValue, NE, LT and LE being their negations, so an
//! unordered lane is true for exactly those three. EQ and NE raise IOC
//! only for a signalling NaN, the ordered conditions for any NaN; an F32
//! denormal reads as zero with IDC (FZ16 is clear here), and -0 equals +0.
//! A lane is compared when any of its bytes is in the mask (VPT, loop
//! tail, EPSR.ECI), its flags count only when its first byte is, and its
//! P0 bits are masked; P0 bytes of done beats keep their value. A VCMP in a
//! block advances it; a VPT opens its mask in each pair whose odd beat is
//! still pending. Qn and Qm are written in that order. fc2=0 with fc0=1,
//! Rm of SP or PC, flipped fixed bits and the 16-bit space are unclaimed.
const defs = @import("fp_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = by_vector ++ by_scalar ++ blocks ++ unclaimed;

const by_vector_01 = @import("fp_by_vector_01.zig");
const by_vector_02 = @import("fp_by_vector_02.zig");

const by_vector = by_vector_01.values ++
    by_vector_02.values;

const by_scalar_01 = @import("fp_by_scalar_01.zig");

const by_scalar = by_scalar_01.values;

const blocks_01 = @import("fp_blocks_01.zig");

const blocks = blocks_01.values;

const unclaimed = [_]V{
    vec("fc2=0 with fc0=1 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F05 }, none),
    vec("the scalar form with fc2=0, fc0=1 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F62 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F4D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F4F }, none),
    vec("the vector form with hw2[5] set is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F24 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F14 }, none),
    vec("hw2[11:8] other than 1111 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0E04 }, none),
    vec("hw1[0] clear is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0F04 }, none),
    vec("integer size 10 is not this group", .{ .hw1 = 0xFE23, .hw2 = 0x0F04 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F04, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
