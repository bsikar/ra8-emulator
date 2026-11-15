//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const ToFixed32 = defs.ToFixed32;

pub const values = [_]ToFixed32{
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "1.5, 1 fraction bit",
        .input = .{ .a = 0x3FC0_0000, .fbits = 1 },
        .expect = .{ .bits = 0x0000_0003 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "1.25 truncates",
        .input = .{ .a = 0x3FA0_0000, .fbits = 1 },
        .expect = .{ .bits = 0x0000_0002, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-1.25 truncates toward zero",
        .input = .{ .a = 0xBFA0_0000, .fbits = 1 },
        .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "1.0 at 31 bits saturates",
        .input = .{ .a = 0x3F80_0000, .fbits = 31 },
        .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-1.0 at 31 bits is exact",
        .input = .{ .a = 0xBF80_0000, .fbits = 31 },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-0.5 at 32 bits",
        .input = .{ .a = 0xBF00_0000, .fbits = 32 },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "a quiet NaN gives 0",
        .input = .{ .a = 0x7FC0_0000, .fbits = 8 },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "1.0 at 32 bits saturates",
        .input = .{ .a = 0x3F80_0000, .fbits = 32, .unsigned = true },
        .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "0.75 at 32 bits",
        .input = .{ .a = 0x3F40_0000, .fbits = 32, .unsigned = true },
        .expect = .{ .bits = 0xC000_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "a negative saturates to 0",
        .input = .{ .a = 0xBF00_0000, .fbits = 4, .unsigned = true },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "1.5 at 8 bits",
        .input = .{ .a = 0x3FC0_0000, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0x0000_0180 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-1.5 comes back sign-extended",
        .input = .{ .a = 0xBFC0_0000, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0xFFFF_FE80 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "128.0 saturates at 16 bits",
        .input = .{ .a = 0x4300_0000, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-128.0 is the 16-bit minimum",
        .input = .{ .a = 0xC300_0000, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0xFFFF_8000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "just above 1 truncates",
        .input = .{ .a = 0x3F80_0001, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0x0000_0100, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "inexact overflow raises IOC only",
        .input = .{ .a = 0x4348_0001, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "255.5 comes back zero-extended",
        .input = .{ .a = 0x437F_8000, .width = 16, .fbits = 8, .unsigned = true },
        .expect = .{ .bits = 0x0000_FF80 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "256.0 saturates at 16 bits",
        .input = .{ .a = 0x4380_0000, .width = 16, .fbits = 8, .unsigned = true },
        .expect = .{ .bits = 0x0000_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "a negative saturates to 0",
        .input = .{ .a = 0xBF80_0000, .width = 16, .fbits = 1, .unsigned = true },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ioc },
    },
};
