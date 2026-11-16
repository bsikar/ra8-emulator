//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("half_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvtb.f16.f32 with ahp: nan to signed zero and infinity to max with ioc",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_7F800000_FF800001_7FC00123,
            .fpscr = 0x04040000,
        },
        .{ .qd = 0x11110000_33337FFF_55558000_77770000, .fpscr = 0x04040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f16.f32 with ahp: exponent 31 values and the ahp overflow",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4808B800_47FFE000_4788B800_80000000,
            .fpscr = 0x04040000,
        },
        .{ .qd = 0x7FFF2222_7FFF4444_7C466666_80008888, .fpscr = 0x04040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtb.f32.f16 with ahp: exponent 31 is an ordinary binade",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFC007C00_840003FF_00017BFF_C1003C00,
            .fpscr = 0x04040000,
        },
        .{ .qd = 0x47800000_387FC000_477FE000_3F800000, .fpscr = 0x04040000, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f32.f16 with ahp: nan patterns read as numbers",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01,
            .fpscr = 0x04040000,
        },
        .{ .qd = 0xC7FFE000_3EAAA000_80000000_47802000, .fpscr = 0x04040000, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBEAAAAAB_3F801800_3F803000_3F802000,
            .fpscr = 0x03C40004,
        },
        .{ .qd = 0x1111B555_33333C01_55553C02_77773C01, .fpscr = 0x03C40014, .vpr = 0x00000000 },
    ),
    vec(
        "qd equal to qm narrows in place",
        .{ .hw1 = 0xEE3F, .hw2 = 0x7E07, .qm = 0x477FF000_477FE000_C0200000_3F800000 },
        .{ .qd = 0x7C00F000_7BFFE000_C1000000_3C000000, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6 widens",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0xEE0D,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFC007C00_840003FF_00017BFF_C1003C00,
        },
        .{ .qd = 0x7F800000_387FC000_477FE000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
};
