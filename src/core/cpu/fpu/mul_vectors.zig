//! Conformance vectors for VMUL and VNMUL, worked from FPMul and FPNeg in the
//! Arm ARM (DDI0553): exact products, signed zeros, infinity times zero,
//! NaN propagation, overflow under RN and RZ, exact and inexact denormal
//! results, FZ on input and output, and VNMUL rounding before it negates.
const vector = @import("../conformance/vector.zig");
const case = @import("case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Binary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Binary(u64), case.Result(u64));

pub const mul32 = [_]V32{
    .{ .encoding = "VMUL.F32 T2", .name = "2*3", .input = .{ .a = 0x4000_0000, .b = 0x4040_0000 }, .expect = .{ .bits = 0x40C0_0000 } },
    .{ .encoding = "VMUL.F32 T2", .name = "-1.5*2", .input = .{ .a = 0xBFC0_0000, .b = 0x4000_0000 }, .expect = .{ .bits = 0xC040_0000 } },
    .{ .encoding = "VMUL.F32 T2", .name = "inf*0", .input = .{ .a = 0x7F80_0000, .b = 0x0000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VMUL.F32 T2", .name = "0*-inf", .input = .{ .a = 0x0000_0000, .b = 0xFF80_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VMUL.F32 T2", .name = "-inf*2", .input = .{ .a = 0xFF80_0000, .b = 0x4000_0000 }, .expect = .{ .bits = 0xFF80_0000 } },
    .{ .encoding = "VMUL.F32 T2", .name = "-0*5", .input = .{ .a = 0x8000_0000, .b = 0x40A0_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VMUL.F32 T2", .name = "+0*-0", .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VMUL.F32 T2", .name = "max*2 overflows", .input = .{ .a = 0x7F7F_FFFF, .b = 0x4000_0000 }, .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VMUL.F32 T2", .name = "max*2, RZ", .input = .{ .a = 0x7F7F_FFFF, .b = 0x4000_0000, .mode = .zero }, .expect = .{ .bits = 0x7F7F_FFFF, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VMUL.F32 T2", .name = "exact denormal result", .input = .{ .a = 0x0080_0000, .b = 0x3F00_0000 }, .expect = .{ .bits = 0x0040_0000 } },
    .{ .encoding = "VMUL.F32 T2", .name = "inexact denormal ties to even", .input = .{ .a = 0x0000_0003, .b = 0x3F00_0000 }, .expect = .{ .bits = 0x0000_0002, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VMUL.F32 T2", .name = "denormal squared, RN", .input = .{ .a = 0x0000_0001, .b = 0x0000_0001 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VMUL.F32 T2", .name = "denormal squared, RP", .input = .{ .a = 0x0000_0001, .b = 0x0000_0001, .mode = .plus_inf }, .expect = .{ .bits = 0x0000_0001, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VMUL.F32 T2", .name = "FZ flushes a denormal input", .input = .{ .a = 0x0000_0001, .b = 0x3F80_0000, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.idc } },
    .{ .encoding = "VMUL.F32 T2", .name = "FZ flushes a tiny result", .input = .{ .a = 0x0080_0000, .b = 0x3F00_0000, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ufc } },
    .{ .encoding = "VMUL.F32 T2", .name = "(1+ulp)^2 rounds", .input = .{ .a = 0x3F80_0001, .b = 0x3F80_0001 }, .expect = .{ .bits = 0x3F80_0002, .flags = f.ixc } },
    .{ .encoding = "VMUL.F32 T2", .name = "qNaN*inf passes through", .input = .{ .a = 0x7FC0_0001, .b = 0x7F80_0000 }, .expect = .{ .bits = 0x7FC0_0001 } },
    .{ .encoding = "VMUL.F32 T2", .name = "0*sNaN", .input = .{ .a = 0x0000_0000, .b = 0x7F80_0002 }, .expect = .{ .bits = 0x7FC0_0002, .flags = f.ioc } },
    .{ .encoding = "VMUL.F32 T2", .name = "DN with sNaN", .input = .{ .a = 0x7F80_0002, .b = 0x3F80_0000, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
};

pub const nmul32 = [_]V32{
    .{ .encoding = "VNMUL.F32 T2", .name = "2*3", .input = .{ .a = 0x4000_0000, .b = 0x4040_0000 }, .expect = .{ .bits = 0xC0C0_0000 } },
    .{ .encoding = "VNMUL.F32 T2", .name = "-0*5", .input = .{ .a = 0x8000_0000, .b = 0x40A0_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VNMUL.F32 T2", .name = "inf*0 negates the default NaN", .input = .{ .a = 0x7F80_0000, .b = 0x0000_0000 }, .expect = .{ .bits = 0xFFC0_0000, .flags = f.ioc } },
    .{ .encoding = "VNMUL.F32 T2", .name = "qNaN sign flips", .input = .{ .a = 0x7FC0_0001, .b = 0x3F80_0000 }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VNMUL.F32 T2", .name = "max*2 overflows", .input = .{ .a = 0x7F7F_FFFF, .b = 0x4000_0000 }, .expect = .{ .bits = 0xFF80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VNMUL.F32 T2", .name = "rounds RP before negating", .input = .{ .a = 0x3F80_0001, .b = 0x3F80_0001, .mode = .plus_inf }, .expect = .{ .bits = 0xBF80_0003, .flags = f.ixc } },
};

pub const mul64 = [_]V64{
    .{ .encoding = "VMUL.F64 T2", .name = "2*3", .input = .{ .a = 0x4000_0000_0000_0000, .b = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x4018_0000_0000_0000 } },
    .{ .encoding = "VMUL.F64 T2", .name = "inf*0", .input = .{ .a = 0x7FF0_0000_0000_0000, .b = 0 }, .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc } },
    .{ .encoding = "VMUL.F64 T2", .name = "(1+ulp)^2 rounds", .input = .{ .a = 0x3FF0_0000_0000_0001, .b = 0x3FF0_0000_0000_0001 }, .expect = .{ .bits = 0x3FF0_0000_0000_0002, .flags = f.ixc } },
    .{ .encoding = "VMUL.F64 T2", .name = "exact denormal result", .input = .{ .a = 0x0010_0000_0000_0000, .b = 0x3FE0_0000_0000_0000 }, .expect = .{ .bits = 0x0008_0000_0000_0000 } },
};

pub const nmul64 = [_]V64{
    .{ .encoding = "VNMUL.F64 T2", .name = "2*3", .input = .{ .a = 0x4000_0000_0000_0000, .b = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0xC018_0000_0000_0000 } },
    .{ .encoding = "VNMUL.F64 T2", .name = "qNaN sign flips", .input = .{ .a = 0x7FF8_0000_0000_0001, .b = 0x3FF0_0000_0000_0000 }, .expect = .{ .bits = 0xFFF8_0000_0000_0001 } },
};

pub const claimed = [_][]const u8{ "VMUL.F32 T2", "VMUL.F64 T2", "VNMUL.F32 T2", "VNMUL.F64 T2" };

pub const covered = vector.encodingsOf(case.Binary(u32), case.Result(u32), &mul32) ++
    vector.encodingsOf(case.Binary(u32), case.Result(u32), &nmul32) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &mul64) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &nmul64);
