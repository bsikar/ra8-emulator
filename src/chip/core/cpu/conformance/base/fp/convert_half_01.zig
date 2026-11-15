//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("convert_types.zig");

const ixc = defs.ixc;
const ofc = defs.ofc;
const raised = defs.raised;
const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvtb.f32.f16 reads the bottom lane",
        .{ .hw1 = 0xEEB2, .hw2 = 0x0A60, .src = 0x4000_3C00 },
        .{ .dst = 0x3F80_0000 },
    ),
    vec(
        "vcvtt.f32.f16 reads the top lane",
        .{ .hw1 = 0xEEB2, .hw2 = 0x0AE0, .src = 0x4000_3C00 },
        .{ .dst = 0x4000_0000 },
    ),
    vec(
        "vcvtb.f16.f32 keeps the top lane",
        .{ .hw1 = 0xEEB3, .hw2 = 0x0A60, .src = 0x3F80_0000 },
        .{ .dst = 0xFFFF_3C00 },
    ),
    vec(
        "vcvtt.f16.f32 keeps the bottom lane",
        .{ .hw1 = 0xEEB3, .hw2 = 0x0AE0, .src = 0x3F80_0000 },
        .{ .dst = 0x3C00_FFFF },
    ),
    vec(
        "vcvtb.f16.f32 overflows to inf",
        .{ .hw1 = 0xEEB3, .hw2 = 0x0A60, .src = 0x4780_0000 },
        .{ .dst = 0xFFFF_7C00, .fpscr = raised(ofc | ixc) },
    ),
    vec(
        "vcvtb.f64.f16 d0, s1",
        .{ .hw1 = 0xEEB2, .hw2 = 0x0B60, .src = 0x3C00, .dst_wide = true },
        .{ .dst = 0x3FF0_0000_0000_0000 },
    ),
    vec(
        "vcvtb.f16.f64 s0, d1",
        .{ .hw1 = 0xEEB3, .hw2 = 0x0B41, .src = 0x3FF0_0000_0000_0000, .src_wide = true },
        .{ .dst = 0xFFFF_3C00 },
    ),
};
