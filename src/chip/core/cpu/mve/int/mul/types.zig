//! MVE multiply fixtures: high-half products, scalar operands, and doubling/saturation forms.

pub const int = @import("../int.zig");

pub const mul = @import("mul.zig");

pub const qreg = @import("../../qreg.zig");

pub const vector = @import("../../../conformance/vector.zig");

pub const HighCase = struct { a: u128, b: u128, size: qreg.Size, high: mul.High };

/// da is the initial destination/accumulator; n is the vector source.
pub const ScalarCase = struct { da: u128, n: u128, scalar: u32, size: qreg.Size, form: mul.ScalarForm };

pub const DoublingCase = struct { da: u128, n: u128, scalar: u32, size: qreg.Size, form: mul.DoublingForm };

pub const VHigh = vector.Vector(HighCase, int.Sat);

pub const VScalar = vector.Vector(ScalarCase, u128);

pub const VDoubling = vector.Vector(DoublingCase, int.Sat);

/// Packed register patterns exercise signed limits and lane selection.
pub const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;

pub const b: u128 = 0x80000000_00000001_01017F81_0001FFFF;

pub const c: u128 = 0x00010002_00030004_FFFEFFFD_7FFF8000;

pub const d: u128 = 0x11223344_55667788_99AABBCC_DDEEFF00;
