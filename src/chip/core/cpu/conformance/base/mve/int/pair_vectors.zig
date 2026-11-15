//! Conformance vectors for the decode group `mve_int_pair` (RA8EMU-278):
//! VQADD, VQSUB, VHADD, VRHADD, VHSUB, VMAX, VMIN and VABD (vector), signed
//! and unsigned at 8, 16 and 32 bits. Expected values are worked from the
//! Arm ARM (DDI0553) pseudocode at full precision then truncated to esize:
//! the saturating pair clamps and raises FPSCR.QC only when the saturating
//! element's first byte is active, the halving forms shift right one with
//! VRHADD adding one first, VABD is the absolute difference. Results merge
//! byte by byte under the VPT mask, the loop tail and EPSR.ECI. Qd, Qn and
//! Qm are written in that order. Size 11, fixed bits flipped, an opc with
//! no instruction, VADD's encoding and the 16-bit space are left unclaimed.
const defs = @import("pair_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = saturating ++ pairwise ++ predicated ++ unclaimed;

const saturating_01 = @import("pair_saturating_01.zig");

const saturating = saturating_01.values;

const pairwise_01 = @import("pair_pairwise_01.zig");
const pairwise_02 = @import("pair_pairwise_02.zig");
const pairwise_03 = @import("pair_pairwise_03.zig");

const pairwise = pairwise_01.values ++
    pairwise_02.values ++
    pairwise_03.values;

const predicated_01 = @import("pair_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEF32, .hw2 = 0x0644 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEF62, .hw2 = 0x0644 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEF23, .hw2 = 0x0644 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x06C4 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0664 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0645 }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x1644 }, none),
    vec("opc 011 x0 is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0344 }, none),
    vec("vadd is not vhadd", .{ .hw1 = 0xEF22, .hw2 = 0x0844 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0644, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
