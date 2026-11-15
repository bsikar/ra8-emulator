//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("convert_types.zig");

const ioc = defs.ioc;
const raised = defs.raised;
const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.f32.s32 s0, s0, #16",
        .{ .hw1 = 0xEEBA, .hw2 = 0x0AC8, .src = 0x0001_8000, .src_reg = 0 },
        .{ .dst = 0x3FC0_0000 },
    ),
    vec(
        "vcvt.s32.f32 s0, s0, #16",
        .{ .hw1 = 0xEEBE, .hw2 = 0x0AC8, .src = 0x3FC0_0000, .src_reg = 0 },
        .{ .dst = 0x0001_8000 },
    ),
    vec(
        "vcvt.u16.f32 s0, s0, #8",
        .{ .hw1 = 0xEEBF, .hw2 = 0x0A44, .src = 0x3FC0_0000, .src_reg = 0 },
        .{ .dst = 0x0180 },
    ),
    vec(
        "vcvt.s16.f32 s0, s0, #8 sign-extends",
        .{ .hw1 = 0xEEBE, .hw2 = 0x0A44, .src = 0xBF80_0000, .src_reg = 0 },
        .{ .dst = 0xFFFF_FF00 },
    ),
    vec(
        "vcvt.s16.f32 s0, s0, #8 saturates",
        .{ .hw1 = 0xEEBE, .hw2 = 0x0A44, .src = 0x4348_0000, .src_reg = 0 },
        .{ .dst = 0x7FFF, .fpscr = raised(ioc) },
    ),
    vec(
        "vcvt.f64.s32 d0, d0, #16",
        .{
            .hw1 = 0xEEBA,
            .hw2 = 0x0BC8,
            .src = 0x0001_8000,
            .src_reg = 0,
            .src_wide = true,
            .dst_wide = true,
        },
        .{ .dst = 0x3FF8_0000_0000_0000 },
    ),
};
