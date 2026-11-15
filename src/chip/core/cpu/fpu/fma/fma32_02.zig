//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const one = defs.one;
const tiny = defs.tiny;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "1 + tiny^2, RP",
        .input = .{ .op = .vfma, .d = one, .n = tiny, .m = tiny, .mode = .plus_inf },
        .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "denormal + 1*1, RN",
        .input = .{ .op = .vfma, .d = 0x0000_0001, .n = one, .m = one },
        .expect = .{ .bits = one, .flags = f.ixc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "-denormal + 1*1, RZ",
        .input = .{ .op = .vfma, .d = 0x8000_0001, .n = one, .m = one, .mode = .zero },
        .expect = .{ .bits = 0x3F7F_FFFF, .flags = f.ixc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "exact denormal result",
        .input = .{ .op = .vfma, .d = 0x0080_0000, .n = 0x3F00_0000, .m = 0x8080_0000 },
        .expect = .{ .bits = 0x0040_0000 },
    },
};
