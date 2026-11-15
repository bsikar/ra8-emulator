//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const f = defs.f;
const Single = defs.Single;

pub const values = [_]Single{
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "1.5 truncates",
        .input = .{ .a = 0x3FC0_0000, .mode = .zero },
        .expect = .{ .bits = 1, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-1.5 truncates",
        .input = .{ .a = 0xBFC0_0000, .mode = .zero },
        .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "2.0 is exact",
        .input = .{ .a = 0x4000_0000, .mode = .zero },
        .expect = .{ .bits = 2 },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-0",
        .input = .{ .a = 0x8000_0000, .mode = .zero },
        .expect = .{ .bits = 0 },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "0.5 truncates to 0",
        .input = .{ .a = 0x3F00_0000, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "2^31 saturates",
        .input = .{ .a = 0x4F00_0000, .mode = .zero },
        .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-2^31 is exact",
        .input = .{ .a = 0xCF00_0000, .mode = .zero },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "largest float below 2^31",
        .input = .{ .a = 0x4EFF_FFFF, .mode = .zero },
        .expect = .{ .bits = 0x7FFF_FF80 },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "+inf saturates",
        .input = .{ .a = 0x7F80_0000, .mode = .zero },
        .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-inf saturates",
        .input = .{ .a = 0xFF80_0000, .mode = .zero },
        .expect = .{ .bits = 0x8000_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "qNaN gives 0",
        .input = .{ .a = 0x7FC0_0000, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "sNaN gives 0",
        .input = .{ .a = 0xFF80_0001, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "a denormal is inexact",
        .input = .{ .a = 0x0000_0001, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "FZ: a denormal is exact 0",
        .input = .{ .a = 0x0000_0001, .mode = .zero, .fz = 1 },
        .expect = .{ .bits = 0, .flags = f.idc },
    },
    .{
        .encoding = "VCVTR",
        .name = "2.5 ties to even, RN",
        .input = .{ .a = 0x4020_0000 },
        .expect = .{ .bits = 2, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTR",
        .name = "3.5 ties to even, RN",
        .input = .{ .a = 0x4060_0000 },
        .expect = .{ .bits = 4, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTR",
        .name = "-2.5 ties to even, RN",
        .input = .{ .a = 0xC020_0000 },
        .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTR",
        .name = "2.5, RP",
        .input = .{ .a = 0x4020_0000, .mode = .plus_inf },
        .expect = .{ .bits = 3, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTR",
        .name = "-2.5, RM",
        .input = .{ .a = 0xC020_0000, .mode = .minus_inf },
        .expect = .{ .bits = 0xFFFF_FFFD, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTR",
        .name = "-2.5, RP",
        .input = .{ .a = 0xC020_0000, .mode = .plus_inf },
        .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc },
    },
};
