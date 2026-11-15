//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("rint_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt p0 0x0f0e computes lane 0 but drops its flags",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBE99999A_C0200000_3FC00000_3F000000,
            .vpr = 0x00880F0E,
        },
        .{ .qd = 0x11111111_C0000000_33333333_00000044, .fpscr = 0x00040010, .vpr = 0x00000F0E },
    ),
    vec(
        "vpt f16 p0 0x3c03",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x0544,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
            .vpr = 0x00883C03,
        },
        .{ .qd = 0x11116400_C2002222_33333333_44443C00, .fpscr = 0x00040000, .vpr = 0x00003C03 },
    ),
    vec(
        "the loop tail drops lanes 2 and 3",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xFF800000_00000001_7FC00001_7F800001,
            .lr = 2,
            .fpscr = 0x00020000,
        },
        .{ .qd = 0x11111111_22222222_7FC00000_7FC00000, .fpscr = 0x00020001 },
    ),
    vec(
        "the f16 loop tail at ltpsize 1",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
            .lr = 5,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x11111111_22224200_8000C000_40000000, .fpscr = 0x00010010 },
    ),
    vec(
        "eci a0a1 keeps the done lanes and their flags",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xFF800000_00000001_7FC00001_7F800001,
            .it = 0x20,
        },
        .{ .qd = 0xFF800000_00000000_33333333_44444444, .fpscr = 0x00040080 },
    ),
};
