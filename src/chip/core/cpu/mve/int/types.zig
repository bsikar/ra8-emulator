//! MVE integer fixtures: packed operands, plain results, and results with saturation status.

pub const int = @import("int.zig");

pub const qreg = @import("../qreg.zig");

pub const vector = @import("../../conformance/vector.zig");

pub const Operands = struct { a: u128, b: u128, size: qreg.Size, unsigned: bool = false };

pub const VPlain = vector.Vector(Operands, u128);

pub const VSat = vector.Vector(Operands, int.Sat);

/// Mixed lane signs and boundary values; lane zero occupies the least-significant bits.
pub const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;

pub const b: u128 = 0x80000000_00000001_01017F81_0001FFFF;

pub const c: u128 = 0x00010002_00030004_FFFEFFFD_7FFF8000;

pub const PairCase = struct { op: int.Pairwise, operands: Operands };

pub const VPair = vector.Vector(PairCase, u128);

pub fn pc(op: int.Pairwise, x: u128, y: u128, size: qreg.Size, unsigned: bool) PairCase {
    return .{ .op = op, .operands = .{ .a = x, .b = y, .size = size, .unsigned = unsigned } };
}
