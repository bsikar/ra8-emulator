//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const case = @import("../case.zig");

pub const vector = @import("../../conformance/vector.zig");

pub const f = case.flag;

pub const V32 = vector.Vector(case.Binary(u32), case.Result(u32));

pub const V64 = vector.Vector(case.Binary(u64), case.Result(u64));

pub const one: u32 = 0x3F80_0000;

pub const three: u32 = 0x4040_0000;
