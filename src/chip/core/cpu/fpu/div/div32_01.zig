//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const one = defs.one;
const three = defs.three;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VDIV",
        .name = "6/3",
        .input = .{ .a = 0x40C0_0000, .b = three },
        .expect = .{ .bits = 0x4000_0000 },
    },
    .{
        .encoding = "VDIV",
        .name = "1/3, RN",
        .input = .{ .a = one, .b = three },
        .expect = .{ .bits = 0x3EAA_AAAB, .flags = f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "1/3, RZ",
        .input = .{ .a = one, .b = three, .mode = .zero },
        .expect = .{ .bits = 0x3EAA_AAAA, .flags = f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "1/3, RP",
        .input = .{ .a = one, .b = three, .mode = .plus_inf },
        .expect = .{ .bits = 0x3EAA_AAAB, .flags = f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "1/3, RM",
        .input = .{ .a = one, .b = three, .mode = .minus_inf },
        .expect = .{ .bits = 0x3EAA_AAAA, .flags = f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "-1/3, RM",
        .input = .{ .a = 0xBF80_0000, .b = three, .mode = .minus_inf },
        .expect = .{ .bits = 0xBEAA_AAAB, .flags = f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "0/0",
        .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VDIV",
        .name = "inf/inf",
        .input = .{ .a = 0x7F80_0000, .b = 0xFF80_0000 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VDIV",
        .name = "1/+0",
        .input = .{ .a = one, .b = 0x0000_0000 },
        .expect = .{ .bits = 0x7F80_0000, .flags = f.dzc },
    },
    .{
        .encoding = "VDIV",
        .name = "-1/+0",
        .input = .{ .a = 0xBF80_0000, .b = 0x0000_0000 },
        .expect = .{ .bits = 0xFF80_0000, .flags = f.dzc },
    },
    .{
        .encoding = "VDIV",
        .name = "1/-0",
        .input = .{ .a = one, .b = 0x8000_0000 },
        .expect = .{ .bits = 0xFF80_0000, .flags = f.dzc },
    },
    .{
        .encoding = "VDIV",
        .name = "inf/0 has no DZC",
        .input = .{ .a = 0x7F80_0000, .b = 0x0000_0000 },
        .expect = .{ .bits = 0x7F80_0000 },
    },
    .{
        .encoding = "VDIV",
        .name = "inf/-2",
        .input = .{ .a = 0x7F80_0000, .b = 0xC000_0000 },
        .expect = .{ .bits = 0xFF80_0000 },
    },
    .{
        .encoding = "VDIV",
        .name = "-0/5",
        .input = .{ .a = 0x8000_0000, .b = 0x40A0_0000 },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VDIV",
        .name = "-1/inf",
        .input = .{ .a = 0xBF80_0000, .b = 0x7F80_0000 },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VDIV",
        .name = "max/0.5 overflows",
        .input = .{ .a = 0x7F7F_FFFF, .b = 0x3F00_0000 },
        .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "max/denormal, RZ",
        .input = .{ .a = 0x7F7F_FFFF, .b = 0x0000_0001, .mode = .zero },
        .expect = .{ .bits = 0x7F7F_FFFF, .flags = f.ofc | f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "smallest normal/2 is exact",
        .input = .{ .a = 0x0080_0000, .b = 0x4000_0000 },
        .expect = .{ .bits = 0x0040_0000 },
    },
    .{
        .encoding = "VDIV",
        .name = "smallest denormal/2, RN",
        .input = .{ .a = 0x0000_0001, .b = 0x4000_0000 },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ufc | f.ixc },
    },
};
