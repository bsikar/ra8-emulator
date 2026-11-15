//! Conformance vectors for VADD and VSUB, worked from FPAdd and FPSub in the
//! Arm ARM (DDI0553): exact sums, ties under every rounding mode, signed
//! zeros, infinities, NaN propagation and priority, default NaN, overflow,
//! exact denormal results, FZ on input, and operands far enough apart that
//! the smaller one only decides the rounding.
const defs = @import("types.zig");

const f = defs.f;

const case = defs.case;
const vector = defs.vector;
pub const V32 = defs.V32;
pub const V64 = defs.V64;

const add32_01 = @import("add32_01.zig");

pub const add32 = add32_01.values;

const sub32_01 = @import("sub32_01.zig");

pub const sub32 = sub32_01.values;

pub const add64 = [_]V64{
    .{
        .encoding = "VADD (floating-point)",
        .name = "1+1",
        .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3FF0_0000_0000_0000 },
        .expect = .{ .bits = 0x4000_0000_0000_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "half ulp ties to even",
        .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3CA0_0000_0000_0000 },
        .expect = .{ .bits = 0x3FF0_0000_0000_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "sNaN is quietened",
        .input = .{ .a = 0x7FF0_0000_0000_0001, .b = 0 },
        .expect = .{ .bits = 0x7FF8_0000_0000_0001, .flags = f.ioc },
    },
};

pub const sub64 = [_]V64{
    .{
        .encoding = "VSUB (floating-point)",
        .name = "1-1, RM",
        .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3FF0_0000_0000_0000, .mode = .minus_inf },
        .expect = .{ .bits = 0x8000_0000_0000_0000 },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "inf - inf",
        .input = .{ .a = 0x7FF0_0000_0000_0000, .b = 0x7FF0_0000_0000_0000 },
        .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "2 - 0.5",
        .input = .{ .a = 0x4000_0000_0000_0000, .b = 0x3FE0_0000_0000_0000 },
        .expect = .{ .bits = 0x3FF8_0000_0000_0000 },
    },
};

pub const claimed = [_][]const u8{
    "VADD (floating-point)",
    "VSUB (floating-point)",
};

pub const covered = vector.encodingsOf(case.Binary(u32), case.Result(u32), &add32) ++
    vector.encodingsOf(case.Binary(u32), case.Result(u32), &sub32) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &add64) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &sub64);
