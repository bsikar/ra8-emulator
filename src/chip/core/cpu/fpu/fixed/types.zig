//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const case = @import("../case.zig");

pub const vector = @import("../../conformance/vector.zig");

pub const f = case.flag;

pub const ToFixed32 = vector.Vector(case.Fraction(u32), case.Result(u32));

pub const ToFixed64 = vector.Vector(case.Fraction(u64), case.Result(u32));

pub const FromFixed32 = vector.Vector(case.Fraction(u32), case.Result(u32));

pub const FromFixed64 = vector.Vector(case.Fraction(u32), case.Result(u64));
