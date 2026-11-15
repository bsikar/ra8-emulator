//! Conformance vectors for the decode group `mve_int_mulh` (RA8EMU-278):
//! VMULH and VRMULH (signed and unsigned) and VQDMULH and VQRDMULH, all
//! vector by vector. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: the high half of each element product, rounded by adding
//! 2^(esize-1) for the R forms, and for the doubling forms twice the
//! product saturated to signed esize, raising FPSCR.QC only when the
//! saturating element's first byte is active. Results merge byte by byte
//! under the VPT mask, the loop tail and EPSR.ECI. Qd, Qn and Qm are
//! written in that order before the instruction runs. Size 11, fixed bits
//! flipped, one form's tail under the other's hw1, VMLA by scalar and the
//! 16-bit space are left unclaimed.
const defs = @import("mulh_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = high ++ doubling ++ predicated ++ unclaimed;

const high_01 = @import("mulh_high_01.zig");

const high = high_01.values;

const doubling_01 = @import("mulh_doubling_01.zig");

const doubling = doubling_01.values;

const predicated_01 = @import("mulh_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("vmulh size 11 is unclaimed", .{ .hw1 = 0xEE31, .hw2 = 0x0E05 }, none),
    vec("vqdmulh size 11 is unclaimed", .{ .hw1 = 0xEF32, .hw2 = 0x0B44 }, none),
    vec("vmulh with hw2[0] clear is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E04 }, none),
    vec("vqdmulh with hw2[0] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0B45 }, none),
    vec("vmulh with n set is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E85 }, none),
    vec("vmulh with m set is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E25 }, none),
    vec("vqdmulh with m clear is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0B04 }, none),
    vec("vmulh with d set is unclaimed", .{ .hw1 = 0xEE61, .hw2 = 0x0E05 }, none),
    vec("vmulh tail under the vqdmulh hw1", .{ .hw1 = 0xEF22, .hw2 = 0x0E05 }, none),
    vec("vmla by scalar is not vmulh", .{ .hw1 = 0xEE23, .hw2 = 0x0E42 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E05, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
