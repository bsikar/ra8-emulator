//! Conformance vectors for the decode group `mve.float.rint` (RA8EMU-278):
//! VRINTN, VRINTX, VRINTA, VRINTZ, VRINTM and VRINTP on F32 and F16 lanes.
//! Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! FPRoundInt under StandardFPSCRValue (DN and FZ set whatever FPSCR holds,
//! FZ16 left clear here). N and X round to nearest even, A to nearest with
//! ties away, Z toward zero, M toward -inf and P toward +inf; only X raises
//! IXC, and only when the value changed. A NaN gives the default NaN (IOC
//! for a signalling one), zeros and infinities return themselves, an F32
//! denormal flushes to a signed zero with IDC, and a zero result keeps the
//! operand's sign. A lane is computed when any of its bytes is in the mask
//! (VPT, loop tail, EPSR.ECI), its flags count only when its first byte is,
//! and the result merges byte by byte. Qd then Qm is written. Sizes 00 and
//! 11, ops 100 and 110, D or M set, flipped fixed bits and the 16-bit space
//! are left unclaimed.
const defs = @import("rint_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = forms ++ predicated ++ unclaimed;

const forms_01 = @import("rint_forms_01.zig");
const forms_02 = @import("rint_forms_02.zig");

const forms = forms_01.values ++
    forms_02.values;

const predicated_01 = @import("rint_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("size 00 is unclaimed", .{ .hw1 = 0xFFB2, .hw2 = 0x0444 }, none),
    vec("size 11 is unclaimed", .{ .hw1 = 0xFFBE, .hw2 = 0x0444 }, none),
    vec("op 100 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0644 }, none),
    vec("op 110 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0744 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xFFFA, .hw2 = 0x0444 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0464 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0445 }, none),
    vec("hw2[12:10] other than 001 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0C44 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0454 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0444, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
