//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fixed_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.s16.f16 #16 fractions",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x868E5640_B8003800_B99A34CD_BD003E00,
        },
        .{ .qd = 0xFFFA7FFF_80007FFF_80004CD0_80007FFF, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s16.f16 #16 nans, infinities, subnormals and saturation",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00,
        },
        .{ .qd = 0x80007FFF_FFFD0000_80007FFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u16.f16 #1 fractions",
        .{
            .hw1 = 0xFFBF,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x868E5640_B8003800_B99A34CD_BD003E00,
        },
        .{ .qd = 0x000000C8_00000001_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u16.f16 #8 fractions",
        .{
            .hw1 = 0xFFB8,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x868E5640_B8003800_B99A34CD_BD003E00,
        },
        .{ .qd = 0x00006400_00000080_0000004C_00000180, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u16.f16 #8 nans, infinities, subnormals and saturation",
        .{
            .hw1 = 0xFFB8,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00,
        },
        .{ .qd = 0x0000FFE0_00000000_0000FFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u16.f16 #16 fractions",
        .{
            .hw1 = 0xFFB0,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x868E5640_B8003800_B99A34CD_BD003E00,
        },
        .{ .qd = 0x0000FFFF_00008000_00004CD0_0000FFFF, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u16.f16 #16 nans, infinities, subnormals and saturation",
        .{
            .hw1 = 0xFFB0,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00,
        },
        .{ .qd = 0x0000FFFF_00000000_0000FFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
};
