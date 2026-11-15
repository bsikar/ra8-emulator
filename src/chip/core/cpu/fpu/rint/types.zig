//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const case = @import("../case.zig");

pub const vector = @import("../../conformance/vector.zig");

pub const f = case.flag;

pub const V32 = vector.Vector(case.Integral(u32), case.Result(u32));

pub const V64 = vector.Vector(case.Integral(u64), case.Result(u64));
