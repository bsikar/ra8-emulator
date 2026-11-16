//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vcadd_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcadd.f32 #90 ordinary values and a rounded sum",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x3E800000_C0600000_40000000_3F800000,
            .qm = 0x3F800000_7149F2CA_C0800000_3F000000,
        },
        .{ .qd = 0x7149F2CA_C0900000_40200000_40A00000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f32 #90 overflow, a flushed denormal and an exact zero",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6,
            .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6,
        },
        .{ .qd = 0x00000000_3F800000_00000000_00000000, .fpscr = 0x00040080, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f32 #90 infinities, nans and signed zeros",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_7FC00001_7F800000_7F800000,
            .qm = 0x7F800001_00000000_7F800000_7F800000,
        },
        .{ .qd = 0x00000000_7FC00000_7F800000_7FC00000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f32 #90 a tiny flushed result and big-number rounding",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x3F800000_4B800000_80000000_00A355E6,
            .qm = 0x3F800000_00000000_0082AB1E_00000000,
        },
        .{ .qd = 0x3F800000_4B7FFFFF_00000000_00000000, .fpscr = 0x00040008, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f16 #90 ordinary values, overflow and rounding",
        .{
            .hw1 = 0xFC82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0xBC007BFF_14195640_3400C300_40003C00,
            .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800,
        },
        .{ .qd = 0xFBFF7BFE_2E765642_3D00C480_41004500, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f16 #90 infinities, nans, subnormals and zeros",
        .{
            .hw1 = 0xFC82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80006800_80000010_00017E01_7C007C00,
            .qm = 0x00003C00_00040008_3C007C01_7C007C00,
        },
        .{ .qd = 0x3C006800_0008000C_7E007E00_7C007E00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f32 #270 ordinary values and a rounded sum",
        .{
            .hw1 = 0xFD92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x3E800000_C0600000_40000000_3F800000,
            .qm = 0x3F800000_7149F2CA_C0800000_3F000000,
        },
        .{ .qd = 0xF149F2CA_C0200000_3FC00000_C0400000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f32 #270 overflow, a flushed denormal and an exact zero",
        .{
            .hw1 = 0xFD92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6,
            .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6,
        },
        .{ .qd = 0x00000000_3F800000_FF800000_7F800000, .fpscr = 0x00040094, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f32 #270 infinities, nans and signed zeros",
        .{
            .hw1 = 0xFD92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_7FC00001_7F800000_7F800000,
            .qm = 0x7F800001_00000000_7F800000_7F800000,
        },
        .{ .qd = 0x80000000_7FC00000_7FC00000_7F800000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f32 #270 a tiny flushed result and big-number rounding",
        .{
            .hw1 = 0xFD92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x3F800000_4B800000_80000000_00A355E6,
            .qm = 0x3F800000_00000000_0082AB1E_00000000,
        },
        .{ .qd = 0x3F800000_4B800000_80000000_01130082, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f16 #270 ordinary values, overflow and rounding",
        .{
            .hw1 = 0xFD82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0xBC007BFF_14195640_3400C300_40003C00,
            .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800,
        },
        .{ .qd = 0x7BFF7C00_AE56563E_BA00C100_3E00C200, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f16 #270 infinities, nans, subnormals and zeros",
        .{
            .hw1 = 0xFD82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80006800_80000010_00017E01_7C007C00,
            .qm = 0x00003C00_00040008_3C007C01_7C007C00,
        },
        .{ .qd = 0xBC006800_80080014_7E007E00_7E007C00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vcadd.f16 #90 with fz16 flushes subnormals without idc",
        .{
            .hw1 = 0xFC82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80006800_80000010_00017E01_7C007C00,
            .qm = 0x00003C00_00040008_3C007C01_7C007C00,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x3C006800_00000000_7E007E00_7C007E00, .fpscr = 0x000C0001, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xFD92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x3E800000_C0600000_40000000_3F800000,
            .qm = 0x3F800000_7149F2CA_C0800000_3F000000,
            .fpscr = 0x03C40010,
        },
        .{ .qd = 0xF149F2CA_C0200000_3FC00000_C0400000, .fpscr = 0x03C40010, .vpr = 0x00000000 },
    ),
    vec(
        "qd equal to qn adds in place",
        .{
            .hw1 = 0xFC96,
            .hw2 = 0x684A,
            .qn = 0x3E800000_C0600000_40000000_3F800000,
            .qm = 0x3F800000_7149F2CA_C0800000_3F000000,
        },
        .{ .qd = 0x7149F2CA_C0900000_40200000_40A00000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6 and q5 at f16",
        .{
            .hw1 = 0xFD8C,
            .hw2 = 0xE84A,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0xBC007BFF_14195640_3400C300_40003C00,
            .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800,
        },
        .{ .qd = 0x7BFF7C00_AE56563E_BA00C100_3E00C200, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};
