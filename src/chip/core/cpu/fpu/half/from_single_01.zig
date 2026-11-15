//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const ToHalf32 = defs.ToHalf32;

pub const values = [_]ToHalf32{
    .{
        .encoding = "VCVTB",
        .name = "1.0 keeps the top half",
        .input = .{ .a = 0x3F80_0000, .d = 0xABCD_1234 },
        .expect = .{ .bits = 0xABCD_3C00 },
    },
    .{
        .encoding = "VCVTT",
        .name = "1.0 into the top half keeps the bottom",
        .input = .{ .a = 0x3F80_0000, .top = true, .d = 0x0000_1234 },
        .expect = .{ .bits = 0x3C00_1234 },
    },
    .{
        .encoding = "VCVTB",
        .name = "65504 is the largest half",
        .input = .{ .a = 0x477F_E000 },
        .expect = .{ .bits = 0x0000_7BFF },
    },
    .{
        .encoding = "VCVTB",
        .name = "65520 overflows to +inf",
        .input = .{ .a = 0x477F_F000 },
        .expect = .{ .bits = 0x0000_7C00, .flags = f.ofc | f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "65520 toward zero stops at the largest half",
        .input = .{ .a = 0x477F_F000, .mode = .zero },
        .expect = .{ .bits = 0x0000_7BFF, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "2^-24 is the smallest denormal, exact",
        .input = .{ .a = 0x3380_0000 },
        .expect = .{ .bits = 0x0000_0001 },
    },
    .{
        .encoding = "VCVTB",
        .name = "2^-25 ties to even zero",
        .input = .{ .a = 0x3300_0000 },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ufc | f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "1+2^-11 ties down to even",
        .input = .{ .a = 0x3F80_1000 },
        .expect = .{ .bits = 0x0000_3C00, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "1+3*2^-11 ties up to even",
        .input = .{ .a = 0x3F80_3000 },
        .expect = .{ .bits = 0x0000_3C02, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "a quiet NaN keeps the top of its payload",
        .input = .{ .a = 0x7FC1_2345 },
        .expect = .{ .bits = 0x0000_7E09 },
    },
    .{
        .encoding = "VCVTB",
        .name = "an sNaN is quieted and signals",
        .input = .{ .a = 0xFF80_0001 },
        .expect = .{ .bits = 0x0000_FE00, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "DN gives the default NaN",
        .input = .{ .a = 0x7FC1_2345, .dn = 1 },
        .expect = .{ .bits = 0x0000_7E00 },
    },
    .{ .encoding = "VCVTB", .name = "-inf", .input = .{ .a = 0xFF80_0000 }, .expect = .{ .bits = 0x0000_FC00 } },
    .{ .encoding = "VCVTB", .name = "-0", .input = .{ .a = 0x8000_0000 }, .expect = .{ .bits = 0x0000_8000 } },
    .{
        .encoding = "VCVTB",
        .name = "FZ flushes a single denormal",
        .input = .{ .a = 0x0000_0001, .fz = 1 },
        .expect = .{ .bits = 0x0000_0000, .flags = f.idc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: 1.0 is unchanged",
        .input = .{ .a = 0x3F80_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_3C00 },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: 65536 is exponent 31",
        .input = .{ .a = 0x4780_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_7C00 },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: 131008 is the largest",
        .input = .{ .a = 0x47FF_E000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_7FFF },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: 131072 saturates with IOC",
        .input = .{ .a = 0x4800_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: a tie into overflow saturates, no IXC",
        .input = .{ .a = 0x47FF_F000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: 131040 toward zero is inexact",
        .input = .{ .a = 0x47FF_F000, .ahp = 1, .mode = .zero },
        .expect = .{ .bits = 0x0000_7FFF, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: 65540 rounds in exponent 31",
        .input = .{ .a = 0x4780_0400, .ahp = 1 },
        .expect = .{ .bits = 0x0000_7C00, .flags = f.ixc },
    },
};
