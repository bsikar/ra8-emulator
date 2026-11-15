//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvt.s32.f32 toward zero, halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0xFFFFFFFF_00000003_FFFFFFFE_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvta.s32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0042,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0xFFFFFFFE_00000004_FFFFFFFD_00000003, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtn.s32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0142,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0xFFFFFFFE_00000004_FFFFFFFE_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtp.s32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0242,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0xFFFFFFFF_00000004_FFFFFFFE_00000003, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtm.s32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0342,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0xFFFFFFFE_00000003_FFFFFFFD_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 saturation",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4F800000_CF000001_4F000000_BF19999A,
        },
        .{ .qd = 0x7FFFFFFF_80000000_7FFFFFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtn.s32.f32 saturation",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0142,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4F800000_CF000001_4F000000_BF19999A,
        },
        .{ .qd = 0x7FFFFFFF_80000000_7FFFFFFF_FFFFFFFF, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 nans, infinity and a flushed denormal",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x80000123_7F800000_FF800001_7FC00000,
        },
        .{ .qd = 0x00000000_7FFFFFFF_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.s32.f32 exact and inexact values",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x3E800000_47F12060_80000000_3F800000,
        },
        .{ .qd = 0x00000000_0001E240_00000000_00000001, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 toward zero, halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0x00000000_00000003_00000000_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvta.u32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x00C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0x00000000_00000004_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtn.u32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x01C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0x00000000_00000004_00000000_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtp.u32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x02C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0x00000000_00000004_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtm.u32.f32 halves",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x03C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBFC00000_40600000_C0200000_40200000,
        },
        .{ .qd = 0x00000000_00000003_00000000_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 saturation",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4F800000_CF000001_4F000000_BF19999A,
        },
        .{ .qd = 0xFFFFFFFF_00000000_80000000_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtn.u32.f32 saturation",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x01C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4F800000_CF000001_4F000000_BF19999A,
        },
        .{ .qd = 0xFFFFFFFF_00000000_80000000_00000000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcvt.u32.f32 nans, infinity and a flushed denormal",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x80000123_7F800000_FF800001_7FC00000,
        },
        .{ .qd = 0x00000000_FFFFFFFF_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
};
