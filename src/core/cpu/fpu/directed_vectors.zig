//! Conformance vectors for VCVTA, VCVTN, VCVTP and VCVTM to S32/U32,
//! worked from FPToFixed in the Arm ARM (DDI0553) with the rounding the
//! encoding fixes (ties away, ties to even, toward +inf, toward -inf)
//! rather than FPSCR's. They cover ties in each direction, negatives that
//! round into or out of an unsigned range, saturation, NaN and FZ.
const vector = @import("../conformance/vector.zig");
const case = @import("case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Directed(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Directed(u64), case.Result(u32));

pub const from_single = [_]V32{
    .{ .encoding = "VCVTA", .name = "2.5 ties away", .input = .{ .a = 0x4020_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0003, .flags = f.ixc } },
    .{ .encoding = "VCVTA", .name = "-2.5 ties away", .input = .{ .a = 0xC020_0000, .rounding = .ties_away }, .expect = .{ .bits = 0xFFFF_FFFD, .flags = f.ixc } },
    .{ .encoding = "VCVTA", .name = "0.5 ties away to 1", .input = .{ .a = 0x3F00_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0001, .flags = f.ixc } },
    .{ .encoding = "VCVTA", .name = "1.4 rounds down", .input = .{ .a = 0x3FB3_3333, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0001, .flags = f.ixc } },
    .{ .encoding = "VCVTA", .name = "2.0 is exact", .input = .{ .a = 0x4000_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0002 } },
    .{ .encoding = "VCVTA", .name = "qNaN gives 0", .input = .{ .a = 0x7FC0_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVTA", .name = "2^31 saturates", .input = .{ .a = 0x4F00_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVTA", .name = "-0.5 ties away to -1 and saturates", .input = .{ .a = 0xBF00_0000, .unsigned = true, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVTA", .name = "-0.4 rounds to 0", .input = .{ .a = 0xBECC_CCCD, .unsigned = true, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0000, .flags = f.ixc } },
    .{ .encoding = "VCVTN", .name = "2.5 ties to even", .input = .{ .a = 0x4020_0000, .rounding = .nearest }, .expect = .{ .bits = 0x0000_0002, .flags = f.ixc } },
    .{ .encoding = "VCVTN", .name = "3.5 ties to even", .input = .{ .a = 0x4060_0000, .rounding = .nearest }, .expect = .{ .bits = 0x0000_0004, .flags = f.ixc } },
    .{ .encoding = "VCVTN", .name = "-0.5 ties to 0", .input = .{ .a = 0xBF00_0000, .rounding = .nearest }, .expect = .{ .bits = 0x0000_0000, .flags = f.ixc } },
    .{ .encoding = "VCVTN", .name = "2.5 ties to even", .input = .{ .a = 0x4020_0000, .unsigned = true, .rounding = .nearest }, .expect = .{ .bits = 0x0000_0002, .flags = f.ixc } },
    .{ .encoding = "VCVTP", .name = "1.1 rounds up", .input = .{ .a = 0x3F8C_CCCD, .rounding = .plus_inf }, .expect = .{ .bits = 0x0000_0002, .flags = f.ixc } },
    .{ .encoding = "VCVTP", .name = "-1.9 rounds up to -1", .input = .{ .a = 0xBFF3_3333, .rounding = .plus_inf }, .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ixc } },
    .{ .encoding = "VCVTP", .name = "-0.5 rounds up to 0", .input = .{ .a = 0xBF00_0000, .unsigned = true, .rounding = .plus_inf }, .expect = .{ .bits = 0x0000_0000, .flags = f.ixc } },
    .{ .encoding = "VCVTM", .name = "1.9 rounds down", .input = .{ .a = 0x3FF3_3333, .rounding = .minus_inf }, .expect = .{ .bits = 0x0000_0001, .flags = f.ixc } },
    .{ .encoding = "VCVTM", .name = "-1.1 rounds down to -2", .input = .{ .a = 0xBF8C_CCCD, .rounding = .minus_inf }, .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc } },
    .{ .encoding = "VCVTM", .name = "FZ: a negative denormal is 0", .input = .{ .a = 0x8000_0001, .rounding = .minus_inf, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.idc } },
    .{ .encoding = "VCVTM", .name = "-0.5 rounds down to -1 and saturates", .input = .{ .a = 0xBF00_0000, .unsigned = true, .rounding = .minus_inf }, .expect = .{ .bits = 0x0000_0000, .flags = f.ioc } },
};

pub const from_double = [_]V64{
    .{ .encoding = "VCVTA", .name = "2.5 ties away", .input = .{ .a = 0x4004_0000_0000_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0003, .flags = f.ixc } },
    .{ .encoding = "VCVTA", .name = "-2^31 - 0.5 ties away out of range", .input = .{ .a = 0xC1E0_0000_0010_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x8000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVTA", .name = "0.5 ties away to 1", .input = .{ .a = 0x3FE0_0000_0000_0000, .unsigned = true, .rounding = .ties_away }, .expect = .{ .bits = 0x0000_0001, .flags = f.ixc } },
    .{ .encoding = "VCVTN", .name = "2.5 ties to even", .input = .{ .a = 0x4004_0000_0000_0000, .rounding = .nearest }, .expect = .{ .bits = 0x0000_0002, .flags = f.ixc } },
    .{ .encoding = "VCVTN", .name = "2^32 - 0.5 ties to even out of range", .input = .{ .a = 0x41EF_FFFF_FFF0_0000, .unsigned = true, .rounding = .nearest }, .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVTP", .name = "-1.5 rounds up to -1", .input = .{ .a = 0xBFF8_0000_0000_0000, .rounding = .plus_inf }, .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ixc } },
    .{ .encoding = "VCVTP", .name = "1.5 rounds up", .input = .{ .a = 0x3FF8_0000_0000_0000, .unsigned = true, .rounding = .plus_inf }, .expect = .{ .bits = 0x0000_0002, .flags = f.ixc } },
    .{ .encoding = "VCVTM", .name = "-1.5 rounds down to -2", .input = .{ .a = 0xBFF8_0000_0000_0000, .rounding = .minus_inf }, .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc } },
    .{ .encoding = "VCVTM", .name = "-0", .input = .{ .a = 0x8000_0000_0000_0000, .rounding = .minus_inf }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VCVTM", .name = "1.5 rounds down", .input = .{ .a = 0x3FF8_0000_0000_0000, .unsigned = true, .rounding = .minus_inf }, .expect = .{ .bits = 0x0000_0001, .flags = f.ixc } },
};

pub const claimed = [_][]const u8{
    "VCVTA",
    "VCVTN",
    "VCVTP",
    "VCVTM",
};

pub const covered = vector.encodingsOf(case.Directed(u32), case.Result(u32), &from_single) ++
    vector.encodingsOf(case.Directed(u64), case.Result(u32), &from_double);
