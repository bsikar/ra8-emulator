//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fixed_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps lanes 1 and 3",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_FF800000_FF800001_7FC00000,
            .vpr = 0x00880F0F,
        },
        .{ .qd = 0x11112222_80000000_55556666_00000000, .fpscr = 0x00040001, .vpr = 0x00000F0F },
    ),
    vec(
        "a lane with byte 0 off is written but its flags drop",
        .{
            .hw1 = 0xFFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_FF800000_FF800001_7FC00000,
            .vpr = 0x0088EEEE,
        },
        .{ .qd = 0x00000022_00000044_00000066_00000088, .fpscr = 0x00040000, .vpr = 0x0000EEEE },
    ),
    vec(
        "f16 lanes count flags from their low byte",
        .{
            .hw1 = 0xEFB8,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00,
            .vpr = 0x0088AAAA,
        },
        .{ .qd = 0x80117F22_00330044_80557F66_00770088, .fpscr = 0x00040000, .vpr = 0x0000AAAA },
    ),
    vec(
        "the loop tail on 16-bit lanes stops after lane 2",
        .{
            .hw1 = 0xFFB8,
            .hw2 = 0x0D52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x11112222_33334444_5555FFFF_00000000, .fpscr = 0x00010001, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xEFB0,
            .hw2 = 0x0F52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x40000000_C7000000_47000000_477FFFFD,
            .it = 0x20,
        },
        .{ .qd = 0x00020000_80000000_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xEFA0,
            .hw2 = 0x0E52,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x12345678_FFFF0000_01000001_00000003,
            .fpscr = 0x03C40001,
        },
        .{ .qd = 0x3D91A2B4_B7800000_3B800000_30400000, .fpscr = 0x03C40011, .vpr = 0x00000000 },
    ),
    vec(
        "qd equal to qm converts in place",
        .{ .hw1 = 0xEFB8, .hw2 = 0x8F58, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 },
        .{ .qd = 0xFFFFFF4D_0000004C_FFFFFEC0_00000180, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6",
        .{
            .hw1 = 0xFFBC,
            .hw2 = 0xEC5C,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001,
        },
        .{ .qd = 0x5C8D6BF8_58003200_68006800_6C002C00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
};
