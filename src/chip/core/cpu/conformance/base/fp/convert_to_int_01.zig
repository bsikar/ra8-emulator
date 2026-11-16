//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("convert_types.zig");

const ioc = defs.ioc;
const ixc = defs.ixc;
const raised = defs.raised;
const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.s32.f32 -2.5 truncates",
        .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .src = 0xC020_0000 },
        .{ .dst = 0xFFFF_FFFE, .fpscr = raised(ixc) },
    ),
    vec(
        "vcvtr.s32.f32 2.5 ties to even",
        .{ .hw1 = 0xEEBD, .hw2 = 0x0A60, .src = 0x4020_0000 },
        .{ .dst = 2, .fpscr = raised(ixc) },
    ),
    vec(
        "vcvtr.s32.f32 3.5 ties to even",
        .{ .hw1 = 0xEEBD, .hw2 = 0x0A60, .src = 0x4060_0000 },
        .{ .dst = 4, .fpscr = raised(ixc) },
    ),
    vec(
        "vcvtr.s32.f32 -2.5 in rm",
        .{ .hw1 = 0xEEBD, .hw2 = 0x0A60, .src = 0xC020_0000, .fpscr = 0x0084_0000 },
        .{ .dst = 0xFFFF_FFFD, .fpscr = 0x0084_0000 | ixc },
    ),
    vec(
        "vcvt.s32.f32 2^31 saturates",
        .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .src = 0x4F00_0000 },
        .{ .dst = 0x7FFF_FFFF, .fpscr = raised(ioc) },
    ),
    vec(
        "vcvt.s32.f32 nan is zero with ioc",
        .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .src = 0x7FC0_0000 },
        .{ .dst = 0, .fpscr = raised(ioc) },
    ),
    vec(
        "vcvt.u32.f32 -1 saturates to zero",
        .{ .hw1 = 0xEEBC, .hw2 = 0x0AE0, .src = 0xBF80_0000 },
        .{ .dst = 0, .fpscr = raised(ioc) },
    ),
    vec(
        "vcvt.u32.f32 2^32 saturates",
        .{ .hw1 = 0xEEBC, .hw2 = 0x0AE0, .src = 0x4F80_0000 },
        .{ .dst = 0xFFFF_FFFF, .fpscr = raised(ioc) },
    ),
    vec("vcvt.u32.f32 3.0 is exact", .{ .hw1 = 0xEEBC, .hw2 = 0x0AE0, .src = 0x4040_0000 }, .{ .dst = 3 }),
    vec(
        "vcvt.s32.f64 s0, d1 -3.75",
        .{ .hw1 = 0xEEBD, .hw2 = 0x0BC1, .src = 0xC00E_0000_0000_0000, .src_wide = true },
        .{ .dst = 0xFFFF_FFFD, .fpscr = raised(ixc) },
    ),
};
