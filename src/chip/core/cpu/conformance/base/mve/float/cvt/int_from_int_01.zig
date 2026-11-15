//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.f32.s32 ordinary and rounded integers",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0642,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x7FFFFFFF_01000001_FFFFFFFF_00000001,
        },
        .{ .qd = 0x4F000000_4B800000_BF800000_3F800000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f32.s32 the top bit and ties to even",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0642,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000000_00000003_01000003_80000000,
        },
        .{ .qd = 0x00000000_40400000_4B800002_CF000000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f16.s16 ordinary and rounded integers",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0642,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000003_10018000_7FFF0801_FFFF0001,
        },
        .{ .qd = 0x00004200_6C00F800_78006800_BC003C00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f16.s16 the overflow edge",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0642,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x04000803_03E8FFFE_8001FFF1_FFEFFFFF,
        },
        .{ .qd = 0x64006802_63D0C000_F800CB80_CC40BC00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f32.u32 ordinary and rounded integers",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x06C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x7FFFFFFF_01000001_FFFFFFFF_00000001,
        },
        .{ .qd = 0x4F000000_4B800000_4F800000_3F800000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f32.u32 the top bit and ties to even",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x06C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000000_00000003_01000003_80000000,
        },
        .{ .qd = 0x00000000_40400000_4B800002_4F000000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f16.u16 ordinary and rounded integers",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x06C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000003_10018000_7FFF0801_FFFF0001,
        },
        .{ .qd = 0x00004200_6C007800_78006800_7C003C00, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.f16.u16 the overflow edge",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x06C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x04000803_03E8FFFE_8001FFF1_FFEFFFFF,
        },
        .{ .qd = 0x64006802_63D07C00_78007C00_7BFF7C00, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};
