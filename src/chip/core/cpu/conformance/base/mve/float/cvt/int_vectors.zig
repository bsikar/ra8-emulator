//! Conformance vectors for the decode group `mve_float_cvt_int`
//! (RA8EMU-278): VCVT between F32 and 32-bit integers and between F16 and
//! 16-bit integers, both ways, and VCVTA/N/P/M float to integer. Expected
//! values are worked from the Arm ARM (DDI0553) FPToFixed and FixedToFP
//! pseudocode under StandardFPSCRValue. Float to integer rounds toward
//! zero (VCVT) or by the encoded mode (ties away, nearest even, toward
//! +inf, toward -inf); a NaN gives 0 with IOC, an infinity or out-of-range
//! value saturates with IOC and no IXC, an inexact result raises IXC, an
//! F32 denormal reads as zero with IDC, and with FZ16 an F16 subnormal
//! reads as zero with no flag. Integer to float rounds to nearest even
//! with IXC, and a 16-bit value past 65520 overflows F16 to infinity with
//! OFC and IXC. A lane runs when any byte is predicated (VPT, loop tail,
//! EPSR.ECI), bytes merge under the mask, and its flags count only when
//! its first byte is. Qd is written before Qm. Sizes 00 and 11, Q8 and
//! above, flipped fixed bits and the 16-bit space are unclaimed.
const defs = @import("int_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = to_int ++ from_int ++ predicated ++ unclaimed;

const to_int_01 = @import("int_to_int_01.zig");
const to_int_02 = @import("int_to_int_02.zig");

const to_int = to_int_01.values ++
    to_int_02.values;

const from_int_01 = @import("int_from_int_01.zig");

const from_int = from_int_01.values;

const predicated_01 = @import("int_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("size 00 is unclaimed", .{ .hw1 = 0xFFB3, .hw2 = 0x0740 }, none),
    vec("size 11 is unclaimed", .{ .hw1 = 0xFFBF, .hw2 = 0x0740 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFFFB, .hw2 = 0x0740 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0760 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0741 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0750 }, none),
    vec("hw2 bit 6 clear is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0700 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x1740 }, none),
    vec("hw2[11:9] = 111 matches neither layout", .{ .hw1 = 0xFFBB, .hw2 = 0x0E40 }, none),
    vec("hw2[11:9] = 010 matches neither layout", .{ .hw1 = 0xFFBB, .hw2 = 0x0440 }, none),
    vec("hw1[1:0] other than 11 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0740 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0740, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
