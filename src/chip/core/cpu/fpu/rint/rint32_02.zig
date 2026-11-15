//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VRINTZ",
        .name = "1.5 truncates",
        .input = .{ .a = 0x3FC0_0000, .rounding = .zero },
        .expect = .{ .bits = 0x3F80_0000 },
    },
    .{
        .encoding = "VRINTZ",
        .name = "2^23 + 1 is already integral",
        .input = .{ .a = 0x4B00_0001, .rounding = .zero },
        .expect = .{ .bits = 0x4B00_0001 },
    },
    .{
        .encoding = "VRINTR",
        .name = "2.5 under RN, no IXC",
        .input = .{ .a = 0x4020_0000, .rounding = .nearest },
        .expect = .{ .bits = 0x4000_0000 },
    },
    .{
        .encoding = "VRINTR",
        .name = "2.5 under RP",
        .input = .{ .a = 0x4020_0000, .rounding = .plus_inf },
        .expect = .{ .bits = 0x4040_0000 },
    },
    .{
        .encoding = "VRINTX",
        .name = "2.5 under RN raises IXC",
        .input = .{ .a = 0x4020_0000, .rounding = .nearest, .exact = true },
        .expect = .{ .bits = 0x4000_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VRINTX",
        .name = "2.0 is exact",
        .input = .{ .a = 0x4000_0000, .rounding = .nearest, .exact = true },
        .expect = .{ .bits = 0x4000_0000 },
    },
    .{
        .encoding = "VRINTX",
        .name = "0.1 under RZ raises IXC",
        .input = .{ .a = 0x3DCC_CCCD, .rounding = .zero, .exact = true },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VRINTX",
        .name = "a denormal under RN is +0 and inexact",
        .input = .{ .a = 0x0000_0001, .rounding = .nearest, .exact = true },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ixc },
    },
};
