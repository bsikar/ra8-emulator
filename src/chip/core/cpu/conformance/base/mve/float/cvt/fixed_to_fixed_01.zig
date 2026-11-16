//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fixed_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.s32.f32 #1 fractions",
        .{
            .hw1 = 0xEFBF,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBF333333_3E99999A_BFA00000_3FC00000,
        },
        .{ .qd = 0xFFFFFFFF_00000000_FFFFFFFE_00000003, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 #16 fractions",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBF333333_3E99999A_BFA00000_3FC00000,
        },
        .{ .qd = 0xFFFF4CCD_00004CCC_FFFEC000_00018000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 #16 saturation",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x40000000_C7000000_47000000_477FFFFD,
        },
        .{ .qd = 0x00020000_80000000_7FFFFFFF_7FFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 #16 nans, infinities and a flushed denormal",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_FF800000_FF800001_7FC00000,
        },
        .{ .qd = 0x00000000_80000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 #32 fractions",
        .{
            .hw1 = 0xEFA0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBF333333_3E99999A_BFA00000_3FC00000,
        },
        .{ .qd = 0x80000000_4CCCCD00_80000000_7FFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 #32 saturation",
        .{
            .hw1 = 0xEFA0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x40000000_C7000000_47000000_477FFFFD,
        },
        .{ .qd = 0x7FFFFFFF_80000000_7FFFFFFF_7FFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 #32 nans, infinities and a flushed denormal",
        .{
            .hw1 = 0xEFA0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_FF800000_FF800001_7FC00000,
        },
        .{ .qd = 0x00000000_80000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 #1 fractions",
        .{
            .hw1 = 0xFFBF,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBF333333_3E99999A_BFA00000_3FC00000,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 #16 fractions",
        .{
            .hw1 = 0xFFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBF333333_3E99999A_BFA00000_3FC00000,
        },
        .{ .qd = 0x00000000_00004CCC_00000000_00018000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 #16 saturation",
        .{
            .hw1 = 0xFFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x40000000_C7000000_47000000_477FFFFD,
        },
        .{ .qd = 0x00020000_00000000_80000000_FFFFFD00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 #16 nans, infinities and a flushed denormal",
        .{
            .hw1 = 0xFFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_FF800000_FF800001_7FC00000,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 #32 fractions",
        .{
            .hw1 = 0xFFA0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBF333333_3E99999A_BFA00000_3FC00000,
        },
        .{ .qd = 0x00000000_4CCCCD00_00000000_FFFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 #32 saturation",
        .{
            .hw1 = 0xFFA0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x40000000_C7000000_47000000_477FFFFD,
        },
        .{ .qd = 0xFFFFFFFF_00000000_FFFFFFFF_FFFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 #32 nans, infinities and a flushed denormal",
        .{
            .hw1 = 0xFFA0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_FF800000_FF800001_7FC00000,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s16.f16 #1 fractions",
        .{
            .hw1 = 0xEFBF,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x868E5640_B8003800_B99A34CD_BD003E00,
        },
        .{ .qd = 0x000000C8_FFFF0001_FFFF0000_FFFE0003, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s16.f16 #8 fractions",
        .{
            .hw1 = 0xEFB8,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x868E5640_B8003800_B99A34CD_BD003E00,
        },
        .{ .qd = 0x00006400_FF800080_FF4D004C_FEC00180, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s16.f16 #8 nans, infinities, subnormals and saturation",
        .{
            .hw1 = 0xEFB8,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00,
        },
        .{ .qd = 0x80007FFF_00000000_80007FFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
};
