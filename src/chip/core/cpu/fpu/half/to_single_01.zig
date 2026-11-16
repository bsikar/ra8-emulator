//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const FromHalf32 = defs.FromHalf32;

pub const values = [_]FromHalf32{
    .{
        .encoding = "VCVTB",
        .name = "1.0 from the bottom half",
        .input = .{ .a = 0x1234_3C00 },
        .expect = .{ .bits = 0x3F80_0000 },
    },
    .{
        .encoding = "VCVTT",
        .name = "-2.0 from the top half",
        .input = .{ .a = 0xC000_1234, .top = true },
        .expect = .{ .bits = 0xC000_0000 },
    },
    .{
        .encoding = "VCVTB",
        .name = "the smallest denormal",
        .input = .{ .a = 0x0000_0001 },
        .expect = .{ .bits = 0x3380_0000 },
    },
    .{
        .encoding = "VCVTB",
        .name = "FZ never flushes a half",
        .input = .{ .a = 0x0000_0001, .fz = 1 },
        .expect = .{ .bits = 0x3380_0000 },
    },
    .{ .encoding = "VCVTB", .name = "65504", .input = .{ .a = 0x0000_7BFF }, .expect = .{ .bits = 0x477F_E000 } },
    .{ .encoding = "VCVTB", .name = "+inf", .input = .{ .a = 0x0000_7C00 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{
        .encoding = "VCVTB",
        .name = "a quiet NaN widens its payload",
        .input = .{ .a = 0x0000_7E09 },
        .expect = .{ .bits = 0x7FC1_2000 },
    },
    .{
        .encoding = "VCVTB",
        .name = "an sNaN is quieted and signals",
        .input = .{ .a = 0x0000_7D00 },
        .expect = .{ .bits = 0x7FE0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "DN gives the default NaN",
        .input = .{ .a = 0x0000_7D00, .dn = 1 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: exponent 31 is 65536",
        .input = .{ .a = 0x0000_7C00, .ahp = 1 },
        .expect = .{ .bits = 0x4780_0000 },
    },
    .{
        .encoding = "VCVTT",
        .name = "AHP: the largest",
        .input = .{ .a = 0x7FFF_0000, .top = true, .ahp = 1 },
        .expect = .{ .bits = 0x47FF_E000 },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: the largest negative",
        .input = .{ .a = 0x0000_FFFF, .ahp = 1 },
        .expect = .{ .bits = 0xC7FF_E000 },
    },
};
