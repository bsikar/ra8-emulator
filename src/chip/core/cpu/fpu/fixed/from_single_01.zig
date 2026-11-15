//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const FromFixed32 = defs.FromFixed32;

pub const values = [_]FromFixed32{
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "3 at 1 bit is 1.5",
        .input = .{ .a = 0x0000_0003, .fbits = 1 },
        .expect = .{ .bits = 0x3FC0_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-1 at 32 bits is -2^-32",
        .input = .{ .a = 0xFFFF_FFFF, .fbits = 32 },
        .expect = .{ .bits = 0xAF80_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "2^31-1 at 31 bits rounds to 1",
        .input = .{ .a = 0x7FFF_FFFF, .fbits = 31 },
        .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "2^31-1 at 31 bits toward zero",
        .input = .{ .a = 0x7FFF_FFFF, .fbits = 31, .mode = .zero },
        .expect = .{ .bits = 0x3F7F_FFFF, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "2^32-1 at 32 bits rounds to 1",
        .input = .{ .a = 0xFFFF_FFFF, .fbits = 32, .unsigned = true },
        .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "2^31 at 32 bits is 0.5",
        .input = .{ .a = 0x8000_0000, .fbits = 32, .unsigned = true },
        .expect = .{ .bits = 0x3F00_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-128 at 8 bits is -0.5",
        .input = .{ .a = 0x0000_FF80, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0xBF00_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "the top 16 bits are ignored",
        .input = .{ .a = 0xABCD_0180, .width = 16, .fbits = 8 },
        .expect = .{ .bits = 0x3FC0_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-32768 at 16 bits is -0.5",
        .input = .{ .a = 0x0000_8000, .width = 16, .fbits = 16 },
        .expect = .{ .bits = 0xBF00_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "65408 at 8 bits is 255.5",
        .input = .{ .a = 0x0000_FF80, .width = 16, .fbits = 8, .unsigned = true },
        .expect = .{ .bits = 0x437F_8000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "1 at 16 bits is 2^-16",
        .input = .{ .a = 0xFFFF_0001, .width = 16, .fbits = 16, .unsigned = true },
        .expect = .{ .bits = 0x3780_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "zero is +0",
        .input = .{ .a = 0x0001_0000, .width = 16, .fbits = 4, .unsigned = true },
        .expect = .{ .bits = 0x0000_0000 },
    },
};
