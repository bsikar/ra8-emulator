//! Conformance vectors for the decode group `mve.int.vqdmlah` (RA8EMU-278):
//! VQDMLAH, VQRDMLAH, VQDMLASH and VQRDMLASH (vector by scalar) at 8, 16
//! and 32 bits. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: per element SignedSatQ((2*Qn*Rm + (Qda << esize) + round)
//! >> esize) for the AH forms and SignedSatQ((2*Qn*Qda + (Rm << esize) +
//! round) >> esize) for the ASH forms, round being 2^(esize-1) for the R
//! forms and Rm its signed low esize bits. FPSCR.QC is raised only when the
//! saturating element's first byte is active. Results merge byte by byte
//! under the VPT mask, the loop tail and EPSR.ECI. Qda and Qn are written
//! in that order. Size 11, Rm of SP or PC, U, D or N set, an unused form,
//! VMLA's encoding and the 16-bit space are left unclaimed.
const defs = @import("vqdmlah_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = forms ++ predicated ++ unclaimed;

const forms_01 = @import("vqdmlah_forms_01.zig");
const forms_02 = @import("vqdmlah_forms_02.zig");

const forms = forms_01.values ++
    forms_02.values;

const predicated_01 = @import("vqdmlah_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0E62 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E6D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E6F }, none),
    vec("u set is unclaimed", .{ .hw1 = 0xFE22, .hw2 = 0x0E62 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEE62, .hw2 = 0x0E62 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0EE2 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E72 }, none),
    vec("bits 6:4 000 are unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E02 }, none),
    vec("vmla is not vqrdmlah", .{ .hw1 = 0xEE23, .hw2 = 0x0E42 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
