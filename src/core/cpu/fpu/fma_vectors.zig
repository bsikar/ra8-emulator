//! Conformance vectors for VFMA, VFMS, VFNMA and VFNMS, worked from
//! FPMulAdd and FPNeg in the Arm ARM (DDI0553). Finite results were checked
//! against an exact rational model rounded per mode. They cover the single
//! rounding (where the chained forms would differ), three-way NaN priority,
//! the quiet-NaN addend with infinity times zero, signed zeros, overflow,
//! and terms far enough apart that one only decides the rounding.
const vector = @import("../conformance/vector.zig");
const case = @import("case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Ternary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Ternary(u64), case.Result(u64));

const one: u32 = 0x3F80_0000;
const tiny: u32 = 0x0DA2_4260;

pub const fma32 = [_]V32{
    .{ .encoding = "VFMA.F32 T2", .name = "1+2*3", .input = .{ .d = one, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x40E0_0000 } },
    .{ .encoding = "VFMA.F32 T2", .name = "one rounding, RN", .input = .{ .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F80_0001 }, .expect = .{ .bits = 0x3480_0000, .flags = f.ixc } },
    .{ .encoding = "VFMA.F32 T2", .name = "one rounding, RP", .input = .{ .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F80_0001, .mode = .plus_inf }, .expect = .{ .bits = 0x3480_0001, .flags = f.ixc } },
    .{ .encoding = "VFMA.F32 T2", .name = "low product bits survive the cancel", .input = .{ .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0x337F_FFFE } },
    .{ .encoding = "VFMA.F32 T2", .name = "qNaN addend with inf*0", .input = .{ .d = 0x7FC0_0001, .n = 0x7F80_0000, .m = 0x0000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VFMA.F32 T2", .name = "1 + inf*0", .input = .{ .d = one, .n = 0x7F80_0000, .m = 0x0000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VFMA.F32 T2", .name = "-inf + inf*2", .input = .{ .d = 0xFF80_0000, .n = 0x7F80_0000, .m = 0x4000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VFMA.F32 T2", .name = "1 + inf*2", .input = .{ .d = one, .n = 0x7F80_0000, .m = 0x4000_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VFMA.F32 T2", .name = "sNaN addend beats a qNaN factor", .input = .{ .d = 0x7F80_0001, .n = 0x7FC0_0002, .m = one }, .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc } },
    .{ .encoding = "VFMA.F32 T2", .name = "sNaN factor beats a qNaN addend", .input = .{ .d = 0x7FC0_0001, .n = 0x7F80_0002, .m = one }, .expect = .{ .bits = 0x7FC0_0002, .flags = f.ioc } },
    .{ .encoding = "VFMA.F32 T2", .name = "qNaN addend beats a qNaN factor", .input = .{ .d = 0x7FC0_0001, .n = 0x7FC0_0002, .m = one }, .expect = .{ .bits = 0x7FC0_0001 } },
    .{ .encoding = "VFMA.F32 T2", .name = "+0 + 1*-0", .input = .{ .d = 0x0000_0000, .n = one, .m = 0x8000_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VFMA.F32 T2", .name = "+0 + 1*-0, RM", .input = .{ .d = 0x0000_0000, .n = one, .m = 0x8000_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VFMA.F32 T2", .name = "-0 + 1*-0", .input = .{ .d = 0x8000_0000, .n = one, .m = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VFMA.F32 T2", .name = "max + max*1 overflows", .input = .{ .d = 0x7F7F_FFFF, .n = 0x7F7F_FFFF, .m = one }, .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VFMA.F32 T2", .name = "FZ flushes a denormal addend", .input = .{ .d = 0x0000_0001, .n = one, .m = one, .fz = 1 }, .expect = .{ .bits = one, .flags = f.idc } },
    .{ .encoding = "VFMA.F32 T2", .name = "1 + tiny^2, RN", .input = .{ .d = one, .n = tiny, .m = tiny }, .expect = .{ .bits = one, .flags = f.ixc } },
    .{ .encoding = "VFMA.F32 T2", .name = "1 + tiny^2, RP", .input = .{ .d = one, .n = tiny, .m = tiny, .mode = .plus_inf }, .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc } },
    .{ .encoding = "VFMA.F32 T2", .name = "denormal + 1*1, RN", .input = .{ .d = 0x0000_0001, .n = one, .m = one }, .expect = .{ .bits = one, .flags = f.ixc } },
    .{ .encoding = "VFMA.F32 T2", .name = "-denormal + 1*1, RZ", .input = .{ .d = 0x8000_0001, .n = one, .m = one, .mode = .zero }, .expect = .{ .bits = 0x3F7F_FFFF, .flags = f.ixc } },
    .{ .encoding = "VFMA.F32 T2", .name = "exact denormal result", .input = .{ .d = 0x0080_0000, .n = 0x3F00_0000, .m = 0x8080_0000 }, .expect = .{ .bits = 0x0040_0000 } },
};

pub const others32 = [_]V32{
    .{ .encoding = "VFMS.F32 T2", .name = "7-2*3", .input = .{ .d = 0x40E0_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = one } },
    .{ .encoding = "VFMS.F32 T2", .name = "low product bits survive the cancel", .input = .{ .d = one, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0xB37F_FFFE } },
    .{ .encoding = "VFMS.F32 T2", .name = "a NaN factor is negated first", .input = .{ .d = one, .n = 0x7FC0_0002, .m = one }, .expect = .{ .bits = 0xFFC0_0002 } },
    .{ .encoding = "VFMS.F32 T2", .name = "6-2*3, RM", .input = .{ .d = 0x40C0_0000, .n = 0x4000_0000, .m = 0x4040_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VFNMA.F32 T2", .name = "-1-2*3", .input = .{ .d = one, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0xC0E0_0000 } },
    .{ .encoding = "VFNMA.F32 T2", .name = "a NaN addend is negated first", .input = .{ .d = 0x7FC0_0001, .n = one, .m = one }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VFNMA.F32 T2", .name = "low product bits survive the cancel", .input = .{ .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0xB37F_FFFE } },
    .{ .encoding = "VFNMS.F32 T2", .name = "2*3-1", .input = .{ .d = one, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x40A0_0000 } },
    .{ .encoding = "VFNMS.F32 T2", .name = "low product bits survive the cancel", .input = .{ .d = one, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0x337F_FFFE } },
    .{ .encoding = "VFNMS.F32 T2", .name = "2*3-6, RM", .input = .{ .d = 0x40C0_0000, .n = 0x4000_0000, .m = 0x4040_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
};

pub const all64 = [_]V64{
    .{ .encoding = "VFMA.F64 T2", .name = "1+2*3", .input = .{ .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x401C_0000_0000_0000 } },
    .{ .encoding = "VFMS.F64 T2", .name = "7-2*3", .input = .{ .d = 0x401C_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VFNMA.F64 T2", .name = "-1-2*3", .input = .{ .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0xC01C_0000_0000_0000 } },
    .{ .encoding = "VFNMS.F64 T2", .name = "2*3-1", .input = .{ .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x4014_0000_0000_0000 } },
    .{ .encoding = "VFMA.F64 T2", .name = "low product bits survive the cancel", .input = .{ .d = 0xBFF0_0000_0000_0000, .n = 0x3FF0_0000_0000_0001, .m = 0x3FEF_FFFF_FFFF_FFFF }, .expect = .{ .bits = 0x3C9F_FFFF_FFFF_FFFE } },
    .{ .encoding = "VFMA.F64 T2", .name = "qNaN addend with inf*0", .input = .{ .d = 0x7FF8_0000_0000_0001, .n = 0x7FF0_0000_0000_0000, .m = 0 }, .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc } },
};

pub const claimed = [_][]const u8{
    "VFMA.F32 T2",  "VFMA.F64 T2",  "VFMS.F32 T2",  "VFMS.F64 T2",
    "VFNMA.F32 T2", "VFNMA.F64 T2", "VFNMS.F32 T2", "VFNMS.F64 T2",
};

pub const covered = vector.encodingsOf(case.Ternary(u32), case.Result(u32), &fma32) ++
    vector.encodingsOf(case.Ternary(u32), case.Result(u32), &others32) ++
    vector.encodingsOf(case.Ternary(u64), case.Result(u64), &all64);
