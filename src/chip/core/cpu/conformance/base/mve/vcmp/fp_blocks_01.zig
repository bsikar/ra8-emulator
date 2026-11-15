//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fp_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt.f32 ge opens a one-instruction block",
        .{
            .hw1 = 0xEE73,
            .hw2 = 0x1F04,
            .qn = 0x80000000_00000000_C0000000_3F800000,
            .qm = 0xBF800000_80000000_40400000_3F800000,
        },
        .{ .vpr = 0x0088FF0F, .fpscr = 0x00040000 },
    ),
    vec(
        "vptt.f16 ne opens a two-instruction block",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x8F84,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
        },
        .{ .vpr = 0x0044FFCC, .fpscr = 0x00040000 },
    ),
    vec(
        "vpteee.f32 lt against r2",
        .{ .hw1 = 0xEE73, .hw2 = 0xDFC2, .qn = 0x80000000_00000000_C0000000_3F800000, .rm = 0x0 },
        .{ .vpr = 0x00EE00F0, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp in a vpt block ands with p0 and drops lane 0 flags",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F05,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
            .vpr = 0x0088FFF0,
        },
        .{ .vpr = 0x00000000, .fpscr = 0x00040081 },
    ),
    vec(
        "the loop tail clears p0 past lane 1",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0F84,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
            .vpr = 0x0000FFFF,
            .lr = 2,
            .fpscr = 0x00020000,
        },
        .{ .vpr = 0x000000FF, .fpscr = 0x00020001 },
    ),
    vec(
        "eci a0a1 keeps the done beats of p0",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F85,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
            .vpr = 0x0000A5A5,
            .it = 0x20,
        },
        .{ .vpr = 0x0000FFA5, .fpscr = 0x00040080 },
    ),
    vec(
        "vpt with eci a0a1a2 opens only mask23",
        .{
            .hw1 = 0xFE73,
            .hw2 = 0x0F04,
            .qn = 0x7BFF7C00_00017E01_80000000_C0003C00,
            .qm = 0xFBFFFC00_00003C00_BC008000_42003C00,
            .vpr = 0x00001234,
            .it = 0x40,
        },
        .{ .vpr = 0x00800234, .fpscr = 0x00040000 },
    ),
};
