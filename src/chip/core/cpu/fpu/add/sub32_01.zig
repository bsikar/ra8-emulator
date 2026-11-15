//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const tiny = defs.tiny;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VSUB (floating-point)",
        .name = "1-1",
        .input = .{ .a = 0x3F80_0000, .b = 0x3F80_0000 },
        .expect = .{ .bits = 0x0000_0000 },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "1-1, RM",
        .input = .{ .a = 0x3F80_0000, .b = 0x3F80_0000, .mode = .minus_inf },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "-1 - -1",
        .input = .{ .a = 0xBF80_0000, .b = 0xBF80_0000 },
        .expect = .{ .bits = 0x0000_0000 },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "-0 - +0",
        .input = .{ .a = 0x8000_0000, .b = 0x0000_0000 },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "smallest normal - smallest denormal",
        .input = .{ .a = 0x0080_0000, .b = 0x0000_0001 },
        .expect = .{ .bits = 0x007F_FFFF },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "inf - inf",
        .input = .{ .a = 0x7F80_0000, .b = 0x7F80_0000 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "1 - -inf",
        .input = .{ .a = 0x3F80_0000, .b = 0xFF80_0000 },
        .expect = .{ .bits = 0x7F80_0000 },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "NaN keeps its own sign",
        .input = .{ .a = 0x3F80_0000, .b = 0xFFC0_0001 },
        .expect = .{ .bits = 0xFFC0_0001 },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "1 - tiny, RN",
        .input = .{ .a = 0x3F80_0000, .b = tiny },
        .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VSUB (floating-point)",
        .name = "1 - tiny, RZ",
        .input = .{ .a = 0x3F80_0000, .b = tiny, .mode = .zero },
        .expect = .{ .bits = 0x3F7F_FFFF, .flags = f.ixc },
    },
};
