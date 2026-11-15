//! Conformance vectors for the decode group `mve_int_scalar` (RA8EMU-278):
//! the vector-by-scalar VADD, VSUB, VMUL, VBRSR, VQ{R}DMULH, VQADD, VQSUB,
//! VHADD and VHSUB. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode with Rm's low esize bits in every lane (VBRSR takes Rm[7:0]
//! as a bit count). Results merge byte by byte under the VPT mask, the loop
//! tail and EPSR.ECI; FPSCR.QC is set only by a saturating element whose
//! first byte is active. Qd and Qn are written in that order first. Size
//! 11, Rm of SP or PC, encodings from the other half, N, D or hw2[4] set,
//! VMLA's encoding and the 16-bit space are left unclaimed.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = modulo ++ saturating ++ predicated ++ unclaimed;

const modulo_01 = @import("scalar_modulo_01.zig");

const modulo = modulo_01.values;

const saturating_01 = @import("scalar_saturating_01.zig");

const saturating = saturating_01.values;

const predicated_01 = @import("scalar_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F42 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F4D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F4F }, none),
    vec("vmul tail in the saturating half", .{ .hw1 = 0xEE22, .hw2 = 0x1E62 }, none),
    vec("vqadd tail in the modulo half", .{ .hw1 = 0xEE23, .hw2 = 0x0F62 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0FC2 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F52 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEE63, .hw2 = 0x0F42 }, none),
    vec("vmla is not vadd", .{ .hw1 = 0xEE23, .hw2 = 0x0E42 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F42, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
