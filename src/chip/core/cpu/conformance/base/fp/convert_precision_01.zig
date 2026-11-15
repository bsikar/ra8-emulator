//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("convert_types.zig");

const ioc = defs.ioc;
const ixc = defs.ixc;
const ofc = defs.ofc;
const raised = defs.raised;
const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.f64.f32 d0, s2",
        .{ .hw1 = 0xEEB7, .hw2 = 0x0AC1, .src = 0x3F80_0000, .src_reg = 2, .dst_wide = true },
        .{ .dst = 0x3FF0_0000_0000_0000 },
    ),
    vec(
        "vcvt.f64.f32 moves a signalling payload up, quieted",
        .{ .hw1 = 0xEEB7, .hw2 = 0x0AC1, .src = 0x7F80_0001, .src_reg = 2, .dst_wide = true },
        .{ .dst = 0x7FF8_0000_2000_0000, .fpscr = raised(ioc) },
    ),
    vec(
        "vcvt.f32.f64 s0, d1 rounds 1/3",
        .{ .hw1 = 0xEEB7, .hw2 = 0x0BC1, .src = 0x3FD5_5555_5555_5555, .src_wide = true },
        .{ .dst = 0x3EAA_AAAB, .fpscr = raised(ixc) },
    ),
    vec(
        "vcvt.f32.f64 overflows to inf",
        .{ .hw1 = 0xEEB7, .hw2 = 0x0BC1, .src = 0x7E37_E43C_8800_759C, .src_wide = true },
        .{ .dst = 0x7F80_0000, .fpscr = raised(ofc | ixc) },
    ),
    vec(
        "vcvt.f32.f64 quiets a signalling nan",
        .{ .hw1 = 0xEEB7, .hw2 = 0x0BC1, .src = 0x7FF0_0000_0000_0001, .src_wide = true },
        .{ .dst = 0x7FC0_0000, .fpscr = raised(ioc) },
    ),
};
