//! Conformance vectors for VDIV, worked from FPDiv in the Arm ARM
//! (DDI0553). Finite results were checked against an exact rational model
//! rounded per mode. They cover each rounding mode on a non-terminating
//! quotient, 0/0 and inf/inf, division by zero (DZC) against infinity over
//! zero (no flag), signed zeros and infinities, NaN propagation, overflow,
//! exact and inexact denormal results, and FZ turning a denormal divisor
//! into a zero.
const defs = @import("types.zig");

const case = defs.case;
const vector = defs.vector;
pub const V32 = defs.V32;
pub const V64 = defs.V64;

const div32_01 = @import("div32_01.zig");
const div32_02 = @import("div32_02.zig");

pub const div32 = div32_01.values ++
    div32_02.values;

const div64_01 = @import("div64_01.zig");

pub const div64 = div64_01.values;

pub const claimed = [_][]const u8{
    "VDIV",
};

pub const covered = vector.encodingsOf(case.Binary(u32), case.Result(u32), &div32) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &div64);
