//! Conformance vectors for the decode group `mve_int_shift` (RA8EMU-278):
//! VSHL, VRSHL, VQSHL and VQRSHL (register), signed and unsigned at 8, 16
//! and 32 bits. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: each Qm element shifts by the signed bottom byte of the
//! matching Qn element, left for positive and arithmetic or logical right
//! for negative, the R forms adding 2^(-1-shift) first when shifting
//! right, the Q forms saturating to esize and raising FPSCR.QC only when
//! the saturating element's first byte is active, the others truncating.
//! Results merge byte by byte under the VPT mask, the loop tail and
//! EPSR.ECI. Qd, Qn and Qm are written in that order. Size 11, fixed bits
//! flipped, VHADD's encoding and the 16-bit space are left unclaimed.
const defs = @import("shift_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = plain ++ saturating ++ predicated ++ unclaimed;

const plain_01 = @import("shift_plain_01.zig");

const plain = plain_01.values;

const saturating_01 = @import("shift_saturating_01.zig");
const saturating_02 = @import("shift_saturating_02.zig");

const saturating = saturating_01.values ++
    saturating_02.values;

const predicated_01 = @import("shift_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEF32, .hw2 = 0x0444 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEF62, .hw2 = 0x0444 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEF23, .hw2 = 0x0444 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x04C4 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0464 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0445 }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x1444 }, none),
    vec("hw2[6] clear is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0404 }, none),
    vec("vhadd is not vshl", .{ .hw1 = 0xEF22, .hw2 = 0x0044 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0444, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
