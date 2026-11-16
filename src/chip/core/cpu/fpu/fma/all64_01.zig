//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const V64 = defs.V64;

pub const values = [_]V64{
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "1+2*3",
        .input = .{
            .op = .vfma,
            .d = 0x3FF0_0000_0000_0000,
            .n = 0x4000_0000_0000_0000,
            .m = 0x4008_0000_0000_0000,
        },
        .expect = .{ .bits = 0x401C_0000_0000_0000 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "7-2*3",
        .input = .{
            .op = .vfms,
            .d = 0x401C_0000_0000_0000,
            .n = 0x4000_0000_0000_0000,
            .m = 0x4008_0000_0000_0000,
        },
        .expect = .{ .bits = 0x3FF0_0000_0000_0000 },
    },
    .{
        .encoding = "VFNMA",
        .name = "-1-2*3",
        .input = .{
            .op = .vfnma,
            .d = 0x3FF0_0000_0000_0000,
            .n = 0x4000_0000_0000_0000,
            .m = 0x4008_0000_0000_0000,
        },
        .expect = .{ .bits = 0xC01C_0000_0000_0000 },
    },
    .{
        .encoding = "VFNMS",
        .name = "2*3-1",
        .input = .{
            .op = .vfnms,
            .d = 0x3FF0_0000_0000_0000,
            .n = 0x4000_0000_0000_0000,
            .m = 0x4008_0000_0000_0000,
        },
        .expect = .{ .bits = 0x4014_0000_0000_0000 },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "low product bits survive the cancel",
        .input = .{
            .op = .vfma,
            .d = 0xBFF0_0000_0000_0000,
            .n = 0x3FF0_0000_0000_0001,
            .m = 0x3FEF_FFFF_FFFF_FFFF,
        },
        .expect = .{ .bits = 0x3C9F_FFFF_FFFF_FFFE },
    },
    .{
        .encoding = "VFMA, VFMS (floating-point)",
        .name = "qNaN addend with inf*0",
        .input = .{ .op = .vfma, .d = 0x7FF8_0000_0000_0001, .n = 0x7FF0_0000_0000_0000, .m = 0 },
        .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc },
    },
};
