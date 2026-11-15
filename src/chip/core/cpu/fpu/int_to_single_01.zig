//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const f = defs.f;
const Single = defs.Single;

pub const values = [_]Single{
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "1",
        .input = .{ .a = 1 },
        .expect = .{ .bits = 0x3F80_0000 },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "-1",
        .input = .{ .a = 0xFFFF_FFFF },
        .expect = .{ .bits = 0xBF80_0000 },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "0 is +0",
        .input = .{ .a = 0 },
        .expect = .{ .bits = 0 },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "INT_MAX, RN",
        .input = .{ .a = 0x7FFF_FFFF },
        .expect = .{ .bits = 0x4F00_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "INT_MAX, RZ",
        .input = .{ .a = 0x7FFF_FFFF, .mode = .zero },
        .expect = .{ .bits = 0x4EFF_FFFF, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "INT_MIN is exact",
        .input = .{ .a = 0x8000_0000 },
        .expect = .{ .bits = 0xCF00_0000 },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "2^24 + 1 ties to even",
        .input = .{ .a = 0x0100_0001 },
        .expect = .{ .bits = 0x4B80_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "2^24 + 3 ties to even",
        .input = .{ .a = 0x0100_0003 },
        .expect = .{ .bits = 0x4B80_0002, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "UINT_MAX, RN",
        .input = .{ .a = 0xFFFF_FFFF, .unsigned = true },
        .expect = .{ .bits = 0x4F80_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "UINT_MAX, RM",
        .input = .{ .a = 0xFFFF_FFFF, .unsigned = true, .mode = .minus_inf },
        .expect = .{ .bits = 0x4F7F_FFFF, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "2^31 is positive",
        .input = .{ .a = 0x8000_0000, .unsigned = true },
        .expect = .{ .bits = 0x4F00_0000 },
    },
};
