//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.u32.f32 exact and inexact values",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x3E800000_47F12060_80000000_3F800000,
        },
        .{ .qd = 0x00000000_0001E240_00000000_00000001, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvta.s16.f16 halves and the extremes",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0042,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100,
        },
        .{ .qd = 0x80007FFF_FFFF0001_FFFE0004_FFFD0003, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtn.s16.f16 halves and the extremes",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0142,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100,
        },
        .{ .qd = 0x80007FFF_00000000_FFFE0004_FFFE0002, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtp.s16.f16 halves and the extremes",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0242,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100,
        },
        .{ .qd = 0x80007FFF_00000001_FFFF0004_FFFE0003, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtm.s16.f16 halves and the extremes",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0342,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100,
        },
        .{ .qd = 0x80007FFF_FFFF0000_FFFE0003_FFFD0002, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s16.f16 toward zero, halves and the extremes",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100,
        },
        .{ .qd = 0x80007FFF_00000000_FFFF0003_FFFE0002, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u16.f16 toward zero, halves and the extremes",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100,
        },
        .{ .qd = 0x0000FFE0_00000000_00000003_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvta.u16.f16 halves and the extremes",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x00C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100,
        },
        .{ .qd = 0x0000FFE0_00000001_00000004_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s16.f16 nans, infinities, a subnormal, 16-bit saturation",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00,
        },
        .{ .qd = 0x80007FFF_00010000_80007FFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u16.f16 nans, infinities, a subnormal, 16-bit saturation",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00,
        },
        .{ .qd = 0x00009C40_00010000_0000FFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtp.s16.f16 with fz16 flushes the subnormal without idc",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0242,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x80007FFF_00020000_80007FFF_00000000, .fpscr = 0x000C0011, .vpr = 0x00000000 },
    ),
};
