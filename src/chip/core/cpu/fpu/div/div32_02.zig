//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const one = defs.one;
const three = defs.three;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VDIV",
        .name = "smallest denormal/2, RP",
        .input = .{ .a = 0x0000_0001, .b = 0x4000_0000, .mode = .plus_inf },
        .expect = .{ .bits = 0x0000_0001, .flags = f.ufc | f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "denormal/denormal",
        .input = .{ .a = 0x0000_0003, .b = 0x0000_0001 },
        .expect = .{ .bits = three },
    },
    .{
        .encoding = "VDIV",
        .name = "1/max is an inexact denormal",
        .input = .{ .a = one, .b = 0x7F7F_FFFF },
        .expect = .{ .bits = 0x0020_0000, .flags = f.ufc | f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "qNaN passes through",
        .input = .{ .a = 0x7FC0_0001, .b = one },
        .expect = .{ .bits = 0x7FC0_0001 },
    },
    .{
        .encoding = "VDIV",
        .name = "sNaN divisor is quietened",
        .input = .{ .a = one, .b = 0xFF80_0002 },
        .expect = .{ .bits = 0xFFC0_0002, .flags = f.ioc },
    },
    .{
        .encoding = "VDIV",
        .name = "a NaN beats 0/0",
        .input = .{ .a = 0x0000_0000, .b = 0x7FC0_0003 },
        .expect = .{ .bits = 0x7FC0_0003 },
    },
    .{
        .encoding = "VDIV",
        .name = "FZ makes a denormal divisor zero",
        .input = .{ .a = one, .b = 0x0000_0001, .fz = 1 },
        .expect = .{ .bits = 0x7F80_0000, .flags = f.dzc | f.idc },
    },
    .{
        .encoding = "VDIV",
        .name = "DN gives the default NaN",
        .input = .{ .a = 0x7FC0_0001, .b = one, .dn = 1 },
        .expect = .{ .bits = 0x7FC0_0000 },
    },
};
