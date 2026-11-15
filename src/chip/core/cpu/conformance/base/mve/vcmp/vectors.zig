//! Conformance vectors for the decode group `mve_vcmp` (RA8EMU-278): the
//! integer VCMP and VPT forms, vector by vector and vector by scalar, at
//! every size and condition. Expected values are worked from the Arm ARM
//! (DDI0553) pseudocode: each element's compare (EQ and NE on the raw
//! bits, CS and HI unsigned, GE, LT, GT and LE signed) sets or clears the
//! P0 bits of its bytes, ANDed with the element mask (VPT P0, the loop
//! tail); P0 bytes of beats EPSR.ECI marks done keep their value. A VCMP
//! inside a block advances it; a VPT then opens its mask in each pair whose
//! odd beat has not run. Qn is written, then Qm for the vector forms only
//! (in the scalar forms those bits are Rm's). Size 11, Rm
//! of SP or PC, fixed bits flipped and the 16-bit space are left unclaimed.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = by_vector ++ by_scalar ++ blocks ++ unclaimed;

const by_vector_01 = @import("by_vector_01.zig");
const by_vector_02 = @import("by_vector_02.zig");

const by_vector = by_vector_01.values ++
    by_vector_02.values;

const by_scalar_01 = @import("by_scalar_01.zig");

const by_scalar = by_scalar_01.values;

const blocks_01 = @import("blocks_01.zig");

const blocks = blocks_01.values;

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xFE33, .hw2 = 0x0F04 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F4D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F4F }, none),
    vec("the vector form with hw2[5] set is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F24 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F14 }, none),
    vec("hw2[11:8] other than 1111 is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0E04 }, none),
    vec("hw1[0] clear is unclaimed", .{ .hw1 = 0xFE22, .hw2 = 0x0F04 }, none),
    vec("hw1[12] clear is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F04 }, none),
    vec("hw1[7] set is unclaimed", .{ .hw1 = 0xFEA3, .hw2 = 0x0F04 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F04, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
