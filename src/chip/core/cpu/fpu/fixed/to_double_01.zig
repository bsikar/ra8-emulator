//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const ToFixed64 = defs.ToFixed64;

pub const values = [_]ToFixed64{
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "2.5 at 2 bits",
        .input = .{ .a = 0x4004_0000_0000_0000, .fbits = 2 },
        .expect = .{ .bits = 0x0000_000A },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "just above 1 truncates",
        .input = .{ .a = 0x3FF0_0000_0000_0001, .fbits = 16 },
        .expect = .{ .bits = 0x0001_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "1.5 at 31 bits",
        .input = .{ .a = 0x3FF8_0000_0000_0000, .fbits = 31, .unsigned = true },
        .expect = .{ .bits = 0xC000_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-0.25 at 16 bits",
        .input = .{ .a = 0xBFD0_0000_0000_0000, .width = 16, .fbits = 16 },
        .expect = .{ .bits = 0xFFFF_C000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "0.5 at 16 bits saturates",
        .input = .{ .a = 0x3FE0_0000_0000_0000, .width = 16, .fbits = 16 },
        .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "0.5 at 16 bits",
        .input = .{ .a = 0x3FE0_0000_0000_0000, .width = 16, .fbits = 16, .unsigned = true },
        .expect = .{ .bits = 0x0000_8000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "+inf saturates",
        .input = .{ .a = 0x7FF0_0000_0000_0000, .width = 16, .fbits = 4, .unsigned = true },
        .expect = .{ .bits = 0x0000_FFFF, .flags = f.ioc },
    },
};
