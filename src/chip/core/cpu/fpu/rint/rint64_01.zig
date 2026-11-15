//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const V64 = defs.V64;

pub const values = [_]V64{
    .{
        .encoding = "VRINTA",
        .name = "2.5 ties away",
        .input = .{ .a = 0x4004_0000_0000_0000, .rounding = .ties_away },
        .expect = .{ .bits = 0x4008_0000_0000_0000 },
    },
    .{
        .encoding = "VRINTN",
        .name = "2.5 ties to even",
        .input = .{ .a = 0x4004_0000_0000_0000, .rounding = .nearest },
        .expect = .{ .bits = 0x4000_0000_0000_0000 },
    },
    .{
        .encoding = "VRINTN",
        .name = "2^52 - 0.5 ties up to even",
        .input = .{ .a = 0x432F_FFFF_FFFF_FFFF, .rounding = .nearest },
        .expect = .{ .bits = 0x4330_0000_0000_0000 },
    },
    .{
        .encoding = "VRINTP",
        .name = "2^52 + 1 is already integral",
        .input = .{ .a = 0x4330_0000_0000_0001, .rounding = .plus_inf },
        .expect = .{ .bits = 0x4330_0000_0000_0001 },
    },
    .{
        .encoding = "VRINTM",
        .name = "-0.5 rounds down to -1",
        .input = .{ .a = 0xBFE0_0000_0000_0000, .rounding = .minus_inf },
        .expect = .{ .bits = 0xBFF0_0000_0000_0000 },
    },
    .{
        .encoding = "VRINTZ",
        .name = "2^52 - 0.5 truncates",
        .input = .{ .a = 0x432F_FFFF_FFFF_FFFF, .rounding = .zero },
        .expect = .{ .bits = 0x432F_FFFF_FFFF_FFFE },
    },
    .{
        .encoding = "VRINTR",
        .name = "1.5 under RN",
        .input = .{ .a = 0x3FF8_0000_0000_0000, .rounding = .nearest },
        .expect = .{ .bits = 0x4000_0000_0000_0000 },
    },
    .{
        .encoding = "VRINTX",
        .name = "-0.5 under RN is -0 and inexact",
        .input = .{ .a = 0xBFE0_0000_0000_0000, .rounding = .nearest, .exact = true },
        .expect = .{ .bits = 0x8000_0000_0000_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VRINTX",
        .name = "qNaN propagates",
        .input = .{ .a = 0x7FF8_0000_0000_0001, .rounding = .nearest, .exact = true },
        .expect = .{ .bits = 0x7FF8_0000_0000_0001 },
    },
};
