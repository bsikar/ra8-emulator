//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const case = @import("case.zig");

pub const vector = @import("../conformance/vector.zig");

pub const f = case.flag;

pub const Single = vector.Vector(case.Fixed(u32), case.Result(u32));

pub const Double = vector.Vector(case.Fixed(u64), case.Result(u32));

pub const ToDouble = vector.Vector(case.Fixed(u32), case.Result(u64));
