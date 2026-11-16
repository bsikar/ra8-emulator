//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const transfer = @import("transfer.zig");

pub const vector = @import("../../conformance/vector.zig");

pub const Many = vector.Vector(transfer.Multiple, transfer.Plan);

pub const One = vector.Vector(transfer.Single, transfer.Plan);
