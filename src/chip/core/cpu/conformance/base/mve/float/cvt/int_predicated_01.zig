//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps lanes 1 and 3",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x80000123_7F800000_FF800001_7FC00000,
            .vpr = 0x00880F0F,
        },
        .{ .qd = 0x11112222_7FFFFFFF_55556666_00000000, .fpscr = 0x00040001, .vpr = 0x00000F0F },
    ),
    vec(
        "a lane with byte 0 off is written but its flags drop",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x80000123_7F800000_FF800001_7FC00000,
            .vpr = 0x0088EEEE,
        },
        .{ .qd = 0x00000022_FFFFFF44_00000066_00000088, .fpscr = 0x00040000, .vpr = 0x0000EEEE },
    ),
    vec(
        "f16 lanes count flags from their low byte",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x0742,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00,
            .vpr = 0x0088AAAA,
        },
        .{ .qd = 0x80117F22_00330044_80557F66_00770088, .fpscr = 0x00040000, .vpr = 0x0000AAAA },
    ),
    vec(
        "the loop tail on 16-bit lanes stops after lane 2",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0x07C2,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x11112222_33334444_5555FFFF_00000000, .fpscr = 0x00010001, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0142,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4F800000_CF000001_4F000000_BF19999A,
            .it = 0x20,
        },
        .{ .qd = 0x7FFFFFFF_80000000_55556666_77778888, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xFFBB,
            .hw2 = 0x0642,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x7FFFFFFF_01000001_FFFFFFFF_00000001,
            .fpscr = 0x03C40001,
        },
        .{ .qd = 0x4F000000_4B800000_BF800000_3F800000, .fpscr = 0x03C40011, .vpr = 0x00000000 },
    ),
    vec(
        "qd equal to qm converts in place",
        .{ .hw1 = 0xFFBB, .hw2 = 0x8348, .qm = 0xBFC00000_40600000_C0200000_40200000 },
        .{ .qd = 0xFFFFFFFE_00000003_FFFFFFFD_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6",
        .{
            .hw1 = 0xFFB7,
            .hw2 = 0xE6CC,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x04000803_03E8FFFE_8001FFF1_FFEFFFFF,
        },
        .{ .qd = 0x64006802_63D07C00_78007C00_7BFF7C00, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};
