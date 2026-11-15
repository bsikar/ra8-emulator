//! Conformance vectors for the decode group `mve_float_vcadd`
//! (RA8EMU-278): floating-point VCADD on F32 and F16 lane pairs, rotation
//! 90 and 270. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: rotation 90 gives (n.re - m.im, n.im + m.re) and 270 the
//! other way, each lane one FPAdd or FPSub under StandardFPSCRValue (round
//! to nearest even, DN and FZ set, FZ16 kept). An F32 denormal operand
//! reads as zero with IDC and an F32 result below the normal range is
//! flushed to zero with UFC; with FZ16 an F16 subnormal operand reads as
//! zero with no flag. NaNs give the default NaN (IOC if signalling), so
//! does +inf - inf; overflow gives infinity with OFC and IXC. A lane runs
//! when any byte is predicated (VPT, loop tail, EPSR.ECI), bytes merge
//! under the mask, and its flags count only when its first byte is. Qd,
//! Qn and Qm are written in that order; Qd never equals Qm here (that is
//! UNPREDICTABLE at F32). Q8 and above, flipped fixed bits and the 16-bit
//! space are unclaimed.
const defs = @import("vcadd_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = rotations ++ predicated ++ unclaimed;

const rotations_01 = @import("vcadd_rotations_01.zig");

const rotations = rotations_01.values;

const predicated_01 = @import("vcadd_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xFC93, .hw2 = 0x0844 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFCD2, .hw2 = 0x0844 }, none),
    vec("hw1 bit 5 set is unclaimed", .{ .hw1 = 0xFCB2, .hw2 = 0x0844 }, none),
    vec("hw1 bit 7 clear is unclaimed", .{ .hw1 = 0xFC12, .hw2 = 0x0844 }, none),
    vec("hw1 bit 9 set is unclaimed", .{ .hw1 = 0xFE92, .hw2 = 0x0844 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x08C4 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0864 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0845 }, none),
    vec("hw2 bit 6 clear is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0804 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x1844 }, none),
    vec("hw2[11:8] other than 1000 is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0944 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
