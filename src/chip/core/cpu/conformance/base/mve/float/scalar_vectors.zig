//! Conformance vectors for the decode group `mve_float_scalar`
//! (RA8EMU-278): VADD, VSUB, VMUL, VFMA (d + n*Rm) and VFMAS (d*n + Rm) on
//! F32 and F16 lanes with Rm broadcast into every lane (its low half for
//! F16). Expected values are worked from the Arm ARM (DDI0553) FPAdd,
//! FPSub, FPMul and FPMulAdd pseudocode under StandardFPSCRValue (round to
//! nearest even, DN and FZ set, FZ16 kept). An F32 denormal operand reads
//! as zero with IDC and a tiny F32 result flushes to zero with UFC; with
//! FZ16 an F16 subnormal reads as zero with no flag. NaNs give the default
//! NaN (IOC if signalling or invalid); overflow gives infinity with OFC
//! and IXC. A lane runs when any of its bytes is predicated (VPT, loop
//! tail, EPSR.ECI), bytes merge under the mask, and its flags count only
//! when its first byte is. Qd then Qn are written, then Rm. Rm of SP or
//! PC, swapped B bits, Q8 and above, flipped fixed bits and the 16-bit
//! space are unclaimed.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = lanes ++ predicated ++ unclaimed;

const lanes_01 = @import("scalar_lanes_01.zig");
const lanes_02 = @import("scalar_lanes_02.zig");
const lanes_03 = @import("scalar_lanes_03.zig");
const lanes_04 = @import("scalar_lanes_04.zig");

const lanes = lanes_01.values ++
    lanes_02.values ++
    lanes_03.values ++
    lanes_04.values;

const predicated_01 = @import("scalar_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("rm of sp is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0E4D }, none),
    vec("rm of pc is unclaimed", .{ .hw1 = 0xEE30, .hw2 = 0x0F4F }, none),
    vec("vmul with b clear is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0E62 }, none),
    vec("vadd with b set is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F42 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEE73, .hw2 = 0x0E42 }, none),
    vec("hw1 bit 8 set is unclaimed", .{ .hw1 = 0xEF33, .hw2 = 0x0E42 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0EC2 }, none),
    vec("hw2 bit 5 set on vadd is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0F62 }, none),
    vec("hw2 bit 12 set on vmul is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x1E62 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
