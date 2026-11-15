//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const tiny = defs.tiny;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VADD (floating-point)",
        .name = "1+1",
        .input = .{ .a = 0x3F80_0000, .b = 0x3F80_0000 },
        .expect = .{ .bits = 0x4000_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "1.5+0.25",
        .input = .{ .a = 0x3FC0_0000, .b = 0x3E80_0000 },
        .expect = .{ .bits = 0x3FE0_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "half ulp ties to even",
        .input = .{ .a = 0x3F80_0000, .b = 0x3380_0000 },
        .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "just over half ulp",
        .input = .{ .a = 0x3F80_0000, .b = 0x3380_0001 },
        .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "+0 + -0",
        .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 },
        .expect = .{ .bits = 0x0000_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "+0 + -0, RM",
        .input = .{ .a = 0x0000_0000, .b = 0x8000_0000, .mode = .minus_inf },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "-0 + -0",
        .input = .{ .a = 0x8000_0000, .b = 0x8000_0000 },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "inf + -inf",
        .input = .{ .a = 0x7F80_0000, .b = 0xFF80_0000 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "inf + 1",
        .input = .{ .a = 0x7F80_0000, .b = 0x3F80_0000 },
        .expect = .{ .bits = 0x7F80_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "qNaN passes through",
        .input = .{ .a = 0x7FC0_0001, .b = 0x3F80_0000 },
        .expect = .{ .bits = 0x7FC0_0001 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "sNaN is quietened",
        .input = .{ .a = 0x3F80_0000, .b = 0x7F80_0001 },
        .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "sNaN beats an earlier qNaN",
        .input = .{ .a = 0x7FC0_0002, .b = 0xFF80_0003 },
        .expect = .{ .bits = 0xFFC0_0003, .flags = f.ioc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "DN gives the default NaN",
        .input = .{ .a = 0x7FC0_0001, .b = 0x3F80_0000, .dn = 1 },
        .expect = .{ .bits = 0x7FC0_0000 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "max + max overflows",
        .input = .{ .a = 0x7F7F_FFFF, .b = 0x7F7F_FFFF },
        .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "denormal + denormal exact",
        .input = .{ .a = 0x0000_0001, .b = 0x0000_0001 },
        .expect = .{ .bits = 0x0000_0002 },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "FZ flushes denormal inputs",
        .input = .{ .a = 0x0000_0001, .b = 0x0000_0001, .fz = 1 },
        .expect = .{ .bits = 0x0000_0000, .flags = f.idc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "1 + tiny, RN",
        .input = .{ .a = 0x3F80_0000, .b = tiny },
        .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VADD (floating-point)",
        .name = "1 + tiny, RP",
        .input = .{ .a = 0x3F80_0000, .b = tiny, .mode = .plus_inf },
        .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc },
    },
};
