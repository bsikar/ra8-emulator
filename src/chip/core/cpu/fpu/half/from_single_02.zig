//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const ToHalf32 = defs.ToHalf32;

pub const values = [_]ToHalf32{
    .{
        .encoding = "VCVTB",
        .name = "AHP: +inf saturates",
        .input = .{ .a = 0x7F80_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: -inf saturates negative",
        .input = .{ .a = 0xFF80_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: a NaN becomes +0",
        .input = .{ .a = 0x7FC0_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: a negative NaN becomes -0",
        .input = .{ .a = 0xFFC0_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_8000, .flags = f.ioc },
    },
};
