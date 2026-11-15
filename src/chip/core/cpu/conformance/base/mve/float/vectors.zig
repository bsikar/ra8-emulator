//! Conformance vectors for the decode group `mve_float` (RA8EMU-278):
//! vector VADD, VSUB, VMUL and VABD on F32 and F16 lanes. Expected values
//! are worked from the Arm ARM (DDI0553) FPAdd, FPSub, FPMul and FPAbs of
//! FPSub pseudocode under StandardFPSCRValue (round to nearest even, DN and
//! FZ set, FZ16 kept). An F32 denormal operand reads as zero with IDC and a
//! tiny F32 result flushes to zero with UFC; with FZ16 an F16 subnormal
//! reads as zero with no flag. NaNs give the default NaN (IOC if signalling
//! or invalid); an exact zero difference is +0; overflow gives infinity
//! with OFC and IXC. A lane runs when any of its bytes is predicated (VPT,
//! loop tail, EPSR.ECI), bytes merge under the mask, and its flags count
//! only when its first byte is. Qd, Qn and Qm are written in that order.
//! The two unused U/op/x combinations, Q8 and above, flipped fixed bits
//! and the 16-bit space are unclaimed.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = lanes ++ predicated ++ unclaimed;

const lanes_01 = @import("lanes_01.zig");
const lanes_02 = @import("lanes_02.zig");
const lanes_03 = @import("lanes_03.zig");

const lanes = lanes_01.values ++
    lanes_02.values ++
    lanes_03.values;

const predicated_01 = @import("predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("u set with op clear and x clear is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0D44 }, none),
    vec("x set on vadd is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D54 }, none),
    vec("x set on vabd is unclaimed", .{ .hw1 = 0xFF22, .hw2 = 0x0D54 }, none),
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xEF03, .hw2 = 0x0D44 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEF42, .hw2 = 0x0D44 }, none),
    vec("hw1 bit 7 set is unclaimed", .{ .hw1 = 0xEF82, .hw2 = 0x0D44 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0DC4 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D64 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x1D44 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D45 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
