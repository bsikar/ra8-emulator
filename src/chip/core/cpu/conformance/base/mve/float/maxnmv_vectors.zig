//! Conformance vectors for the decode group `mve_float_maxnmv` (RA8EMU-278):
//! VMAXNMV, VMINNMV, VMAXNMAV and VMINNMAV on F32 and F16 lanes, folding
//! the predicated lanes of Qm into Rda. Expected values are worked from the
//! Arm ARM (DDI0553) pseudocode: lane by lane, a signalling NaN in the
//! running value or the lane is quietened with IOC, the AV forms take the
//! lane's absolute value (never Rda's), and FPMaxNum or FPMinNum runs under
//! StandardFPSCRValue (an F32 denormal reads as zero with IDC; FZ16 is
//! clear here, so F16 denormals stay). Only lanes whose first byte is in
//! the mask (VPT, loop tail) fold. The F16 forms read Rda's low half and
//! zero-extend the result. Rda of SP or PC, M set, the integer VMAXV space,
//! flipped fixed bits and the 16-bit space are left unclaimed.
const defs = @import("maxnmv_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = forms ++ predicated ++ unclaimed;

const forms_01 = @import("maxnmv_forms_01.zig");
const forms_02 = @import("maxnmv_forms_02.zig");

const forms = forms_01.values ++
    forms_02.values;

const predicated_01 = @import("maxnmv_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("rda = sp is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0xDF02 }, none),
    vec("rda = pc is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0xFF02 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F22 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F03 }, none),
    vec("hw2[6] set is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F42 }, none),
    vec("hw2[11:8] other than 1111 is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2E02 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEEEF, .hw2 = 0x2F02 }, none),
    vec("integer vmaxv size 10 is not this group", .{ .hw1 = 0xEEE2, .hw2 = 0x2F02 }, none),
    vec("hw1[15:13] other than 111 is unclaimed", .{ .hw1 = 0xCEEE, .hw2 = 0x2F02 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
