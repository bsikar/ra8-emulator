//! Conformance vectors for the decode group `mve_float_cvt_half`
//! (RA8EMU-278): VCVTB and VCVTT between F32 and F16 lanes, both ways.
//! Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! FPConvert under StandardFPSCRValue (round to nearest even, DN and FZ
//! set, AHP and FZ16 kept). Narrowing flushes an F32 denormal with IDC, a
//! NaN becomes the default NaN (IOC if signalling), a tiny inexact result
//! raises UFC and IXC (tininess before rounding), an overflow OFC and IXC;
//! with AHP a NaN becomes a signed zero and an infinity or overflow the
//! largest magnitude, each with IOC only. Widening is exact; with AHP the
//! exponent-31 half patterns are ordinary numbers. Narrowing writes the
//! bottom or top half of each Qd word and keeps the other; widening reads
//! that half of each Qm word. A lane runs when any byte is predicated (VPT,
//! loop tail, EPSR.ECI), bytes merge under the mask, and its flags count
//! only when byte 0 (narrow, or VCVTB widen) or byte 2 (VCVTT widen) is.
//! Qd is written before Qm. Q8 and above, flipped fixed bits, VMAXNMA's
//! bit 7 and the 16-bit space are unclaimed.
const defs = @import("half_types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const In = defs.In;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = conversions ++ modes ++ predicated ++ unclaimed;

const conversions_01 = @import("half_conversions_01.zig");

const conversions = conversions_01.values;

const modes_01 = @import("half_modes_01.zig");

const modes = modes_01.values;

const predicated_01 = @import("half_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("hw2 bit 7 set is vmaxnma, not this group", .{ .hw1 = 0xEE3F, .hw2 = 0x0E83 }, none),
    vec("hw2 bit 0 clear is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E02 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEE7F, .hw2 = 0x0E03 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E23 }, none),
    vec("hw1 low nibble other than 1111 is unclaimed", .{ .hw1 = 0xEE3E, .hw2 = 0x0E03 }, none),
    vec("hw1[5:4] other than 11 is unclaimed", .{ .hw1 = 0xEE2F, .hw2 = 0x0E03 }, none),
    vec("hw2[11:8] other than 1110 is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0F03 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E13 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
