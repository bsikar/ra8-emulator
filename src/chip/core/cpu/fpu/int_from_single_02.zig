//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const f = defs.f;
const Single = defs.Single;

pub const values = [_]Single{
    .{
        .encoding = "VCVTR",
        .name = "0.4, RP",
        .input = .{ .a = 0x3ECC_CCCD, .mode = .plus_inf },
        .expect = .{ .bits = 1, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "1.5 truncates",
        .input = .{ .a = 0x3FC0_0000, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 1, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-0.5 truncates to 0",
        .input = .{ .a = 0xBF00_0000, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-1 saturates to 0",
        .input = .{ .a = 0xBF80_0000, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "2^32 saturates",
        .input = .{ .a = 0x4F80_0000, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "largest float below 2^32",
        .input = .{ .a = 0x4F7F_FFFF, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0xFFFF_FF00 },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-inf saturates to 0",
        .input = .{ .a = 0xFF80_0000, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTR",
        .name = "-0.5 ties to 0, RN",
        .input = .{ .a = 0xBF00_0000, .unsigned = true },
        .expect = .{ .bits = 0, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTR",
        .name = "-0.7 rounds to -1 and saturates",
        .input = .{ .a = 0xBF33_3333, .unsigned = true },
        .expect = .{ .bits = 0, .flags = f.ioc },
    },
};
