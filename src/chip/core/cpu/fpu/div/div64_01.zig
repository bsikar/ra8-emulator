//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const V64 = defs.V64;

pub const values = [_]V64{
    .{
        .encoding = "VDIV",
        .name = "6/3",
        .input = .{ .a = 0x4018_0000_0000_0000, .b = 0x4008_0000_0000_0000 },
        .expect = .{ .bits = 0x4000_0000_0000_0000 },
    },
    .{
        .encoding = "VDIV",
        .name = "1/3",
        .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4008_0000_0000_0000 },
        .expect = .{ .bits = 0x3FD5_5555_5555_5555, .flags = f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "1/7, RP",
        .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x401C_0000_0000_0000, .mode = .plus_inf },
        .expect = .{ .bits = 0x3FC2_4924_9249_2493, .flags = f.ixc },
    },
    .{
        .encoding = "VDIV",
        .name = "1/0",
        .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0 },
        .expect = .{ .bits = 0x7FF0_0000_0000_0000, .flags = f.dzc },
    },
    .{
        .encoding = "VDIV",
        .name = "0/0",
        .input = .{ .a = 0, .b = 0 },
        .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VDIV",
        .name = "smallest denormal/2",
        .input = .{ .a = 1, .b = 0x4000_0000_0000_0000 },
        .expect = .{ .bits = 0, .flags = f.ufc | f.ixc },
    },
};
