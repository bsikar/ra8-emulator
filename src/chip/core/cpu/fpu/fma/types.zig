//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const case = @import("../case.zig");

pub const vector = @import("../../conformance/vector.zig");

pub const f = case.flag;

pub const V32 = vector.Vector(case.Ternary(u32), case.Result(u32));

pub const V64 = vector.Vector(case.Ternary(u64), case.Result(u64));

pub const one: u32 = 0x3F80_0000;

pub const tiny: u32 = 0x0DA2_4260;
