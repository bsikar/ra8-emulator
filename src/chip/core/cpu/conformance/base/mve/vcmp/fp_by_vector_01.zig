//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fp_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmp.f32 eq ordered and signed zeros",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0F04,
            .qn = 0x80000000_00000000_C0000000_3F800000,
            .qm = 0xBF800000_80000000_40400000_3F800000,
        },
        .{ .vpr = 0x00000F0F, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 eq nans, a flushed denormal, infinities",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0F04,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
        },
        .{ .vpr = 0x0000FF00, .fpscr = 0x00040081 },
    ),
    vec(
        "vcmp.f16 eq mixed lanes with a quiet nan",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0F04,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
        },
        .{ .vpr = 0x00000033, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 ne ordered and signed zeros",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0F84,
            .qn = 0x80000000_00000000_C0000000_3F800000,
            .qm = 0xBF800000_80000000_40400000_3F800000,
        },
        .{ .vpr = 0x0000F0F0, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 ne nans, a flushed denormal, infinities",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0F84,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
        },
        .{ .vpr = 0x000000FF, .fpscr = 0x00040081 },
    ),
    vec(
        "vcmp.f16 ne mixed lanes with a quiet nan",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0F84,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
        },
        .{ .vpr = 0x0000FFCC, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 ge ordered and signed zeros",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F04,
            .qn = 0x80000000_00000000_C0000000_3F800000,
            .qm = 0xBF800000_80000000_40400000_3F800000,
        },
        .{ .vpr = 0x0000FF0F, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 ge nans, a flushed denormal, infinities",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F04,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
        },
        .{ .vpr = 0x0000FF00, .fpscr = 0x00040081 },
    ),
    vec(
        "vcmp.f16 ge mixed lanes with a quiet nan",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x1F04,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
        },
        .{ .vpr = 0x0000FCF3, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 lt ordered and signed zeros",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F84,
            .qn = 0x80000000_00000000_C0000000_3F800000,
            .qm = 0xBF800000_80000000_40400000_3F800000,
        },
        .{ .vpr = 0x000000F0, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 lt nans, a flushed denormal, infinities",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F84,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
        },
        .{ .vpr = 0x000000FF, .fpscr = 0x00040081 },
    ),
    vec(
        "vcmp.f16 lt mixed lanes with a quiet nan",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x1F84,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
        },
        .{ .vpr = 0x0000030C, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 gt ordered and signed zeros",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F05,
            .qn = 0x80000000_00000000_C0000000_3F800000,
            .qm = 0xBF800000_80000000_40400000_3F800000,
        },
        .{ .vpr = 0x0000F000, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 gt nans, a flushed denormal, infinities",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F05,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
        },
        .{ .vpr = 0x00000000, .fpscr = 0x00040081 },
    ),
    vec(
        "vcmp.f16 gt mixed lanes with a quiet nan",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x1F05,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
        },
        .{ .vpr = 0x0000FCC0, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 le ordered and signed zeros",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F85,
            .qn = 0x80000000_00000000_C0000000_3F800000,
            .qm = 0xBF800000_80000000_40400000_3F800000,
        },
        .{ .vpr = 0x00000FFF, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f32 le nans, a flushed denormal, infinities",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F85,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
        },
        .{ .vpr = 0x0000FFFF, .fpscr = 0x00040081 },
    ),
    vec(
        "vcmp.f16 le mixed lanes with a quiet nan",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x1F85,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
        },
        .{ .vpr = 0x0000033F, .fpscr = 0x00040001 },
    ),
};
