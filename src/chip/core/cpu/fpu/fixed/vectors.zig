//! Conformance vectors for VCVT between floating point and fixed point,
//! worked from FPToFixed and FixedToFP in the Arm ARM (DDI0553). They cover
//! 16- and 32-bit integer sides, fbits from 1 to 32, truncation toward
//! zero, saturation at 16 bits (IOC without IXC) and at 32, results
//! extended by signedness, the ignored top half of a 16-bit operand, both
//! rounding directions back to float, NaN, infinity and FZ.
const defs = @import("types.zig");

const case = defs.case;
const vector = defs.vector;
pub const ToFixed32 = defs.ToFixed32;
pub const ToFixed64 = defs.ToFixed64;
pub const FromFixed32 = defs.FromFixed32;
pub const FromFixed64 = defs.FromFixed64;

const to_single_01 = @import("to_single_01.zig");
const to_single_02 = @import("to_single_02.zig");

pub const to_single = to_single_01.values ++
    to_single_02.values;

const to_double_01 = @import("to_double_01.zig");

pub const to_double = to_double_01.values;

const from_single_01 = @import("from_single_01.zig");

pub const from_single = from_single_01.values;

const from_double_01 = @import("from_double_01.zig");

pub const from_double = from_double_01.values;

pub const claimed = [_][]const u8{
    "VCVT (between floating-point and fixed-point)",
};

pub const covered = vector.encodingsOf(case.Fraction(u32), case.Result(u32), &to_single) ++
    vector.encodingsOf(case.Fraction(u64), case.Result(u32), &to_double) ++
    vector.encodingsOf(case.Fraction(u32), case.Result(u32), &from_single) ++
    vector.encodingsOf(case.Fraction(u32), case.Result(u64), &from_double);
