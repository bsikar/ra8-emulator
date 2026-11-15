//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fixed_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.f16.u16 #16 set 1",
        .{
            .hw1 = 0xFFB0,
            .hw2 = 0x0C52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001,
        },
        .{ .qd = 0x2C8D3BF8_28000300_38003800_3C000100, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f16.s16 #16 with fz16 flushes the subnormal results with ufc",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0C52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x2C8D9C00_28000000_3800B800_80000000, .fpscr = 0x000C0018, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s16.f16 #8 with fz16 reads subnormals as zero without idc",
        .{
            .hw1 = 0xEFB8,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x80007FFF_00000000_80007FFF_00000000, .fpscr = 0x000C0001, .vpr = 0x00000000 },
    ),
};
