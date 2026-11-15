//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const case = @import("../case.zig");

pub const vector = @import("../../conformance/vector.zig");

pub const f = case.flag;

pub const ToHalf32 = vector.Vector(case.Halves(u32), case.Result(u32));

pub const ToHalf64 = vector.Vector(case.Halves(u64), case.Result(u32));

pub const FromHalf32 = vector.Vector(case.Halves(u32), case.Result(u32));

pub const FromHalf64 = vector.Vector(case.Halves(u32), case.Result(u64));
