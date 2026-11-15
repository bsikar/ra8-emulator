//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("system_types.zig");

const equal = defs.equal;
const flags = defs.flags;
const greater = defs.greater;
const less = defs.less;
const one = defs.one;
const qnan = defs.qnan;
const snan = defs.snan;
const two = defs.two;
const unordered = defs.unordered;
const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec("vcmp.f32 1 < 2", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = one, .b = two }, .{ .fpscr = flags(less, false) }),
    vec("vcmp.f32 2 > 1", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = two, .b = one }, .{ .fpscr = flags(greater, false) }),
    vec("vcmp.f32 1 == 1", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = one, .b = one }, .{ .fpscr = flags(equal, false) }),
    vec(
        "vcmp.f32 +0 == -0",
        .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = 0, .b = 0x8000_0000 },
        .{ .fpscr = flags(equal, false) },
    ),
    vec(
        "vcmp.f32 +inf > 1",
        .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = 0x7F80_0000, .b = one },
        .{ .fpscr = flags(greater, false) },
    ),
    vec(
        "vcmp.f32 quiet nan is unordered without ioc",
        .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = qnan, .b = one },
        .{ .fpscr = flags(unordered, false) },
    ),
    vec(
        "vcmpe.f32 quiet nan raises ioc",
        .{ .hw1 = 0xEEB4, .hw2 = 0x0AE0, .a = qnan, .b = one },
        .{ .fpscr = flags(unordered, true) },
    ),
    vec(
        "vcmp.f32 signalling nan raises ioc",
        .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = one, .b = snan },
        .{ .fpscr = flags(unordered, true) },
    ),
    vec(
        "vcmp.f32 s1, s0 takes D as the low bit",
        .{ .hw1 = 0xEEF4, .hw2 = 0x0A40, .a = one, .b = two },
        .{ .fpscr = flags(greater, false) },
    ),
    vec(
        "vcmp.f32 -1 against zero",
        .{ .hw1 = 0xEEB5, .hw2 = 0x0A40, .a = 0xBF80_0000 },
        .{ .fpscr = flags(less, false) },
    ),
    vec(
        "vcmp.f32 -0 against zero is equal",
        .{ .hw1 = 0xEEB5, .hw2 = 0x0A40, .a = 0x8000_0000 },
        .{ .fpscr = flags(equal, false) },
    ),
    vec(
        "vcmp.f64 1 < 2",
        .{
            .hw1 = 0xEEB4,
            .hw2 = 0x0B41,
            .double = true,
            .a = 0x3FF0_0000_0000_0000,
            .b = 0x4000_0000_0000_0000,
        },
        .{ .fpscr = flags(less, false) },
    ),
    vec(
        "vcmpe.f64 quiet nan against zero",
        .{ .hw1 = 0xEEB5, .hw2 = 0x0BC0, .double = true, .a = 0x7FF8_0000_0000_0000 },
        .{ .fpscr = flags(unordered, true) },
    ),
    vec(
        "vcmp.f16 1 < 2",
        .{ .hw1 = 0xEEB4, .hw2 = 0x0960, .a = 0x3C00, .b = 0x4000 },
        .{ .fpscr = flags(less, false) },
    ),
    vec(
        "vcmp.f16 2 > 1",
        .{ .hw1 = 0xEEB4, .hw2 = 0x0960, .a = 0x4000, .b = 0x3C00 },
        .{ .fpscr = flags(greater, false) },
    ),
};
