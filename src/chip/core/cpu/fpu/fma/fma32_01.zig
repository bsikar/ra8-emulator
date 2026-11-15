//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const one = defs.one;
const tiny = defs.tiny;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "1+2*3",
        .input = .{ .op = .vfma, .d = one, .n = 0x4000_0000, .m = 0x4040_0000 },
        .expect = .{ .bits = 0x40E0_0000 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "one rounding, RN",
        .input = .{ .op = .vfma, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F80_0001 },
        .expect = .{ .bits = 0x3480_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "one rounding, RP",
        .input = .{
            .op = .vfma,
            .d = 0xBF80_0000,
            .n = 0x3F80_0001,
            .m = 0x3F80_0001,
            .mode = .plus_inf,
        },
        .expect = .{ .bits = 0x3480_0001, .flags = f.ixc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "low product bits survive the cancel",
        .input = .{ .op = .vfma, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF },
        .expect = .{ .bits = 0x337F_FFFE },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "qNaN addend with inf*0",
        .input = .{ .op = .vfma, .d = 0x7FC0_0001, .n = 0x7F80_0000, .m = 0x0000_0000 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "1 + inf*0",
        .input = .{ .op = .vfma, .d = one, .n = 0x7F80_0000, .m = 0x0000_0000 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "-inf + inf*2",
        .input = .{ .op = .vfma, .d = 0xFF80_0000, .n = 0x7F80_0000, .m = 0x4000_0000 },
        .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "1 + inf*2",
        .input = .{ .op = .vfma, .d = one, .n = 0x7F80_0000, .m = 0x4000_0000 },
        .expect = .{ .bits = 0x7F80_0000 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "sNaN addend beats a qNaN factor",
        .input = .{ .op = .vfma, .d = 0x7F80_0001, .n = 0x7FC0_0002, .m = one },
        .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "sNaN factor beats a qNaN addend",
        .input = .{ .op = .vfma, .d = 0x7FC0_0001, .n = 0x7F80_0002, .m = one },
        .expect = .{ .bits = 0x7FC0_0002, .flags = f.ioc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "qNaN addend beats a qNaN factor",
        .input = .{ .op = .vfma, .d = 0x7FC0_0001, .n = 0x7FC0_0002, .m = one },
        .expect = .{ .bits = 0x7FC0_0001 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "+0 + 1*-0",
        .input = .{ .op = .vfma, .d = 0x0000_0000, .n = one, .m = 0x8000_0000 },
        .expect = .{ .bits = 0x0000_0000 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "+0 + 1*-0, RM",
        .input = .{ .op = .vfma, .d = 0x0000_0000, .n = one, .m = 0x8000_0000, .mode = .minus_inf },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "-0 + 1*-0",
        .input = .{ .op = .vfma, .d = 0x8000_0000, .n = one, .m = 0x8000_0000 },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "max + max*1 overflows",
        .input = .{ .op = .vfma, .d = 0x7F7F_FFFF, .n = 0x7F7F_FFFF, .m = one },
        .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "FZ flushes a denormal addend",
        .input = .{ .op = .vfma, .d = 0x0000_0001, .n = one, .m = one, .fz = 1 },
        .expect = .{ .bits = one, .flags = f.idc },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "1 + tiny^2, RN",
        .input = .{ .op = .vfma, .d = one, .n = tiny, .m = tiny },
        .expect = .{ .bits = one, .flags = f.ixc },
    },
};
