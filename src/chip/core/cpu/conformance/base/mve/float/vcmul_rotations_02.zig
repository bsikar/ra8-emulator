//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vcmul_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmul.f32 #270 overflow, underflow and infinity times zero",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x1E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
        },
        .{ .qd = 0x80000000_00000000_FF800000_BF800000, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcmul.f32 #270 nans, a flushed denormal and signed zeros",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x1E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
        },
        .{ .qd = 0x00000000_7FC00000_80000000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcmul.f16 #270 ordinary values, overflow and a subnormal",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x1E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0x80027C00_C200068E_BB34CD40_4600BC00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcmul.f16 #270 infinities, nans and subnormals",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x1E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
        },
        .{ .qd = 0xAC190011_00008000_BC007E00_80008000, .fpscr = 0x00040019, .vpr = 0x00000000 },
    ),
    vec(
        "vcmul.f16 #0 with fz16 flushes subnormals",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x0E04,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x3C197C00_00000000_7E007E00_FC007C00, .fpscr = 0x000C0015, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x0E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
            .fpscr = 0x03C40010,
        },
        .{ .qd = 0x3F666667_41A80000_C0C00000_3F800000, .fpscr = 0x03C40010, .vpr = 0x00000000 },
    ),
    vec(
        "qn equal to qm squares the pair",
        .{
            .hw1 = 0xFE38,
            .hw2 = 0x0E08,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6 and q5 at f16",
        .{
            .hw1 = 0xEE3C,
            .hw2 = 0xFE0B,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0x80027C00_C200068E_BB34CD40_4600BC00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
};
