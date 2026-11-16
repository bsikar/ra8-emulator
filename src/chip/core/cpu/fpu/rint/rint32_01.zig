//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VRINTA",
        .name = "2.5 ties away",
        .input = .{ .a = 0x4020_0000, .rounding = .ties_away },
        .expect = .{ .bits = 0x4040_0000 },
    },
    .{
        .encoding = "VRINTA",
        .name = "-2.5 ties away",
        .input = .{ .a = 0xC020_0000, .rounding = .ties_away },
        .expect = .{ .bits = 0xC040_0000 },
    },
    .{
        .encoding = "VRINTA",
        .name = "0.5 ties away to 1",
        .input = .{ .a = 0x3F00_0000, .rounding = .ties_away },
        .expect = .{ .bits = 0x3F80_0000 },
    },
    .{
        .encoding = "VRINTA",
        .name = "-0.4 keeps its sign as -0",
        .input = .{ .a = 0xBECC_CCCD, .rounding = .ties_away },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VRINTA",
        .name = "qNaN propagates",
        .input = .{ .a = 0xFFC0_0001, .rounding = .ties_away },
        .expect = .{ .bits = 0xFFC0_0001 },
    },
    .{
        .encoding = "VRINTA",
        .name = "sNaN is quietened",
        .input = .{ .a = 0x7F80_0001, .rounding = .ties_away },
        .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc },
    },
    .{
        .encoding = "VRINTA",
        .name = "DN gives the default NaN",
        .input = .{ .a = 0xFFC0_0001, .rounding = .ties_away, .dn = 1 },
        .expect = .{ .bits = 0x7FC0_0000 },
    },
    .{
        .encoding = "VRINTA",
        .name = "-inf",
        .input = .{ .a = 0xFF80_0000, .rounding = .ties_away },
        .expect = .{ .bits = 0xFF80_0000 },
    },
    .{
        .encoding = "VRINTN",
        .name = "2.5 ties to even",
        .input = .{ .a = 0x4020_0000, .rounding = .nearest },
        .expect = .{ .bits = 0x4000_0000 },
    },
    .{
        .encoding = "VRINTN",
        .name = "3.5 ties to even",
        .input = .{ .a = 0x4060_0000, .rounding = .nearest },
        .expect = .{ .bits = 0x4080_0000 },
    },
    .{
        .encoding = "VRINTN",
        .name = "-0.5 ties to -0",
        .input = .{ .a = 0xBF00_0000, .rounding = .nearest },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VRINTN",
        .name = "-0 stays -0",
        .input = .{ .a = 0x8000_0000, .rounding = .nearest },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VRINTP",
        .name = "1.1 rounds up",
        .input = .{ .a = 0x3F8C_CCCD, .rounding = .plus_inf },
        .expect = .{ .bits = 0x4000_0000 },
    },
    .{
        .encoding = "VRINTP",
        .name = "-0.5 rounds up to -0",
        .input = .{ .a = 0xBF00_0000, .rounding = .plus_inf },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VRINTP",
        .name = "-1.9 rounds up to -1",
        .input = .{ .a = 0xBFF3_3333, .rounding = .plus_inf },
        .expect = .{ .bits = 0xBF80_0000 },
    },
    .{
        .encoding = "VRINTP",
        .name = "a denormal rounds up to 1",
        .input = .{ .a = 0x0000_0001, .rounding = .plus_inf },
        .expect = .{ .bits = 0x3F80_0000 },
    },
    .{
        .encoding = "VRINTM",
        .name = "1.9 rounds down",
        .input = .{ .a = 0x3FF3_3333, .rounding = .minus_inf },
        .expect = .{ .bits = 0x3F80_0000 },
    },
    .{
        .encoding = "VRINTM",
        .name = "-1.1 rounds down to -2",
        .input = .{ .a = 0xBF8C_CCCD, .rounding = .minus_inf },
        .expect = .{ .bits = 0xC000_0000 },
    },
    .{
        .encoding = "VRINTM",
        .name = "0.4 rounds down to +0",
        .input = .{ .a = 0x3ECC_CCCD, .rounding = .minus_inf },
        .expect = .{ .bits = 0x0000_0000 },
    },
    .{
        .encoding = "VRINTM",
        .name = "FZ: a negative denormal is -0",
        .input = .{ .a = 0x8000_0001, .rounding = .minus_inf, .fz = 1 },
        .expect = .{ .bits = 0x8000_0000, .flags = f.idc },
    },
    .{
        .encoding = "VRINTZ",
        .name = "-1.9 truncates",
        .input = .{ .a = 0xBFF3_3333, .rounding = .zero },
        .expect = .{ .bits = 0xBF80_0000 },
    },
};
