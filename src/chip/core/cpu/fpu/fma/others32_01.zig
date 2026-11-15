//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const one = defs.one;
const V32 = defs.V32;

pub const values = [_]V32{
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "7-2*3",
        .input = .{ .op = .vfms, .d = 0x40E0_0000, .n = 0x4000_0000, .m = 0x4040_0000 },
        .expect = .{ .bits = one },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "low product bits survive the cancel",
        .input = .{ .op = .vfms, .d = one, .n = 0x3F80_0001, .m = 0x3F7F_FFFF },
        .expect = .{ .bits = 0xB37F_FFFE },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "a NaN factor is negated first",
        .input = .{ .op = .vfms, .d = one, .n = 0x7FC0_0002, .m = one },
        .expect = .{ .bits = 0xFFC0_0002 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "6-2*3, RM",
        .input = .{
            .op = .vfms,
            .d = 0x40C0_0000,
            .n = 0x4000_0000,
            .m = 0x4040_0000,
            .mode = .minus_inf,
        },
        .expect = .{ .bits = 0x8000_0000 },
    },
    .{
        .encoding = "VFNMA",
        .name = "-1-2*3",
        .input = .{ .op = .vfnma, .d = one, .n = 0x4000_0000, .m = 0x4040_0000 },
        .expect = .{ .bits = 0xC0E0_0000 },
    },
    .{
        .encoding = "VFNMA",
        .name = "a NaN addend is negated first",
        .input = .{ .op = .vfnma, .d = 0x7FC0_0001, .n = one, .m = one },
        .expect = .{ .bits = 0xFFC0_0001 },
    },
    .{
        .encoding = "VFNMA",
        .name = "low product bits survive the cancel",
        .input = .{ .op = .vfnma, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF },
        .expect = .{ .bits = 0xB37F_FFFE },
    },
    .{
        .encoding = "VFNMS",
        .name = "2*3-1",
        .input = .{ .op = .vfnms, .d = one, .n = 0x4000_0000, .m = 0x4040_0000 },
        .expect = .{ .bits = 0x40A0_0000 },
    },
    .{
        .encoding = "VFNMS",
        .name = "low product bits survive the cancel",
        .input = .{ .op = .vfnms, .d = one, .n = 0x3F80_0001, .m = 0x3F7F_FFFF },
        .expect = .{ .bits = 0x337F_FFFE },
    },
    .{
        .encoding = "VFNMS",
        .name = "2*3-6, RM",
        .input = .{
            .op = .vfnms,
            .d = 0x40C0_0000,
            .n = 0x4000_0000,
            .m = 0x4040_0000,
            .mode = .minus_inf,
        },
        .expect = .{ .bits = 0x8000_0000 },
    },
};
