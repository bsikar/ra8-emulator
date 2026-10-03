//! Conformance vectors for VCVT and VCVTR between floating point and 32-bit
//! integers, worked from FPToFixed and FixedToFP in the Arm ARM (DDI0553)
//! with fbits 0. They cover truncation and each rounding mode, ties,
//! saturation at both ends (IOC, not IXC), negative values into an
//! unsigned result, infinities, NaNs, denormals with and without FZ, and
//! integers that need rounding to fit a float.
const vector = @import("../conformance/vector.zig");
const case = @import("case.zig");
const f = case.flag;

pub const Single = vector.Vector(case.Fixed(u32), case.Result(u32));
pub const Double = vector.Vector(case.Fixed(u64), case.Result(u32));
pub const ToDouble = vector.Vector(case.Fixed(u32), case.Result(u64));

pub const from_single = [_]Single{
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "1.5 truncates", .input = .{ .a = 0x3FC0_0000, .mode = .zero }, .expect = .{ .bits = 1, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-1.5 truncates", .input = .{ .a = 0xBFC0_0000, .mode = .zero }, .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "2.0 is exact", .input = .{ .a = 0x4000_0000, .mode = .zero }, .expect = .{ .bits = 2 } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-0", .input = .{ .a = 0x8000_0000, .mode = .zero }, .expect = .{ .bits = 0 } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "0.5 truncates to 0", .input = .{ .a = 0x3F00_0000, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "2^31 saturates", .input = .{ .a = 0x4F00_0000, .mode = .zero }, .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-2^31 is exact", .input = .{ .a = 0xCF00_0000, .mode = .zero }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "largest float below 2^31", .input = .{ .a = 0x4EFF_FFFF, .mode = .zero }, .expect = .{ .bits = 0x7FFF_FF80 } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "+inf saturates", .input = .{ .a = 0x7F80_0000, .mode = .zero }, .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-inf saturates", .input = .{ .a = 0xFF80_0000, .mode = .zero }, .expect = .{ .bits = 0x8000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "qNaN gives 0", .input = .{ .a = 0x7FC0_0000, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "sNaN gives 0", .input = .{ .a = 0xFF80_0001, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "a denormal is inexact", .input = .{ .a = 0x0000_0001, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "FZ: a denormal is exact 0", .input = .{ .a = 0x0000_0001, .mode = .zero, .fz = 1 }, .expect = .{ .bits = 0, .flags = f.idc } },
    .{ .encoding = "VCVTR", .name = "2.5 ties to even, RN", .input = .{ .a = 0x4020_0000 }, .expect = .{ .bits = 2, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "3.5 ties to even, RN", .input = .{ .a = 0x4060_0000 }, .expect = .{ .bits = 4, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "-2.5 ties to even, RN", .input = .{ .a = 0xC020_0000 }, .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "2.5, RP", .input = .{ .a = 0x4020_0000, .mode = .plus_inf }, .expect = .{ .bits = 3, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "-2.5, RM", .input = .{ .a = 0xC020_0000, .mode = .minus_inf }, .expect = .{ .bits = 0xFFFF_FFFD, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "-2.5, RP", .input = .{ .a = 0xC020_0000, .mode = .plus_inf }, .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "0.4, RP", .input = .{ .a = 0x3ECC_CCCD, .mode = .plus_inf }, .expect = .{ .bits = 1, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "1.5 truncates", .input = .{ .a = 0x3FC0_0000, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 1, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-0.5 truncates to 0", .input = .{ .a = 0xBF00_0000, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-1 saturates to 0", .input = .{ .a = 0xBF80_0000, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "2^32 saturates", .input = .{ .a = 0x4F80_0000, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "largest float below 2^32", .input = .{ .a = 0x4F7F_FFFF, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0xFFFF_FF00 } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-inf saturates to 0", .input = .{ .a = 0xFF80_0000, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ioc } },
    .{ .encoding = "VCVTR", .name = "-0.5 ties to 0, RN", .input = .{ .a = 0xBF00_0000, .unsigned = true }, .expect = .{ .bits = 0, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "-0.7 rounds to -1 and saturates", .input = .{ .a = 0xBF33_3333, .unsigned = true }, .expect = .{ .bits = 0, .flags = f.ioc } },
};

pub const from_double = [_]Double{
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "2^31 - 0.5 truncates", .input = .{ .a = 0x41DF_FFFF_FFE0_0000, .mode = .zero }, .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ixc } },
    .{ .encoding = "VCVTR", .name = "2^31 - 0.5 rounds out of range", .input = .{ .a = 0x41DF_FFFF_FFE0_0000 }, .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-2^31 - 0.5 truncates", .input = .{ .a = 0xC1E0_0000_0010_0000, .mode = .zero }, .expect = .{ .bits = 0x8000_0000, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "1e300 saturates", .input = .{ .a = 0x7E37_E43C_8800_759C, .mode = .zero }, .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "-1e300 saturates", .input = .{ .a = 0xFE37_E43C_8800_759C, .mode = .zero }, .expect = .{ .bits = 0x8000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "2^32 - 1 is exact", .input = .{ .a = 0x41EF_FFFF_FFE0_0000, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0xFFFF_FFFF } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "2^32 saturates", .input = .{ .a = 0x41F0_0000_0000_0000, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and integer)", .name = "smallest denormal", .input = .{ .a = 1, .unsigned = true, .mode = .zero }, .expect = .{ .bits = 0, .flags = f.ixc } },
};

pub const to_single = [_]Single{
    .{ .encoding = "VCVT (integer to floating-point)", .name = "1", .input = .{ .a = 1 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "-1", .input = .{ .a = 0xFFFF_FFFF }, .expect = .{ .bits = 0xBF80_0000 } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "0 is +0", .input = .{ .a = 0 }, .expect = .{ .bits = 0 } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "INT_MAX, RN", .input = .{ .a = 0x7FFF_FFFF }, .expect = .{ .bits = 0x4F00_0000, .flags = f.ixc } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "INT_MAX, RZ", .input = .{ .a = 0x7FFF_FFFF, .mode = .zero }, .expect = .{ .bits = 0x4EFF_FFFF, .flags = f.ixc } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "INT_MIN is exact", .input = .{ .a = 0x8000_0000 }, .expect = .{ .bits = 0xCF00_0000 } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "2^24 + 1 ties to even", .input = .{ .a = 0x0100_0001 }, .expect = .{ .bits = 0x4B80_0000, .flags = f.ixc } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "2^24 + 3 ties to even", .input = .{ .a = 0x0100_0003 }, .expect = .{ .bits = 0x4B80_0002, .flags = f.ixc } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "UINT_MAX, RN", .input = .{ .a = 0xFFFF_FFFF, .unsigned = true }, .expect = .{ .bits = 0x4F80_0000, .flags = f.ixc } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "UINT_MAX, RM", .input = .{ .a = 0xFFFF_FFFF, .unsigned = true, .mode = .minus_inf }, .expect = .{ .bits = 0x4F7F_FFFF, .flags = f.ixc } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "2^31 is positive", .input = .{ .a = 0x8000_0000, .unsigned = true }, .expect = .{ .bits = 0x4F00_0000 } },
};

pub const to_double = [_]ToDouble{
    .{ .encoding = "VCVT (integer to floating-point)", .name = "INT_MIN", .input = .{ .a = 0x8000_0000 }, .expect = .{ .bits = 0xC1E0_0000_0000_0000 } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "INT_MAX is exact", .input = .{ .a = 0x7FFF_FFFF }, .expect = .{ .bits = 0x41DF_FFFF_FFC0_0000 } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "UINT_MAX is exact", .input = .{ .a = 0xFFFF_FFFF, .unsigned = true }, .expect = .{ .bits = 0x41EF_FFFF_FFE0_0000 } },
    .{ .encoding = "VCVT (integer to floating-point)", .name = "0 is +0", .input = .{ .a = 0, .unsigned = true }, .expect = .{ .bits = 0 } },
};

pub const claimed = [_][]const u8{
    "VCVT (between floating-point and integer)",
    "VCVTR",
    "VCVT (integer to floating-point)",
};

pub const covered = vector.encodingsOf(case.Fixed(u32), case.Result(u32), &from_single) ++
    vector.encodingsOf(case.Fixed(u64), case.Result(u32), &from_double) ++
    vector.encodingsOf(case.Fixed(u32), case.Result(u32), &to_single) ++
    vector.encodingsOf(case.Fixed(u32), case.Result(u64), &to_double);
