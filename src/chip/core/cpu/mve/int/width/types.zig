//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const int = @import("../int.zig");

pub const qreg = @import("../../qreg.zig");

pub const vector = @import("../../../conformance/vector.zig");

pub const width = @import("width.zig");

pub const NarrowCase = struct { d: u128, m: u128, size: qreg.Size, half: width.Half, spec: width.Narrow };

pub const WidenCase = struct { m: u128, size: qreg.Size, half: width.Half, unsigned: bool, left: u6 };

pub const VNarrow = vector.Vector(NarrowCase, int.Sat);

pub const VWiden = vector.Vector(WidenCase, u128);

pub const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;

pub const d: u128 = 0x11223344_55667788_99AABBCC_DDEEFF00;

pub const m: u128 = 0xFFFF8000_00017FFF_FFFFFF7F_00000080;
