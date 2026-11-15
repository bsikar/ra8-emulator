//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("half_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcvtb.f16.f32 ordinary values, max finite and the overflow edge",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x477FF000_477FE000_C0200000_3F800000,
        },
        .{ .qd = 0x11117C00_33337BFF_5555C100_77773C00, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtb.f16.f32 ties to even and inexact rounding",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBEAAAAAB_3F801800_3F803000_3F802000,
        },
        .{ .qd = 0x1111B555_33333C01_55553C02_77773C01, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtb.f16.f32 subnormal results raise ufc only when inexact",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x358637BD_32FFFAE5_33800000_38800000,
        },
        .{ .qd = 0x11110011_33330000_55550001_77770400, .fpscr = 0x00040018, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtb.f16.f32 nans to the default nan, infinity, a flushed denormal",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_7F800000_FF800001_7FC00123,
        },
        .{ .qd = 0x11110000_33337C00_55557E00_77777E00, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtb.f16.f32 signed zero, large values, more overflow",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4808B800_47FFE000_4788B800_80000000,
        },
        .{ .qd = 0x11117C00_33337C00_55557C00_77778000, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtb.f32.f16 normals, max, subnormals, infinities",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFC007C00_840003FF_00017BFF_C1003C00,
        },
        .{ .qd = 0x7F800000_387FC000_477FE000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtb.f32.f16 nans and zeros",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01,
        },
        .{ .qd = 0x7FC00000_00000000_7FC00000_7FC00000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f16.f32 ordinary values, max finite and the overflow edge",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x477FF000_477FE000_C0200000_3F800000,
        },
        .{ .qd = 0x7C002222_7BFF4444_C1006666_3C008888, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f16.f32 ties to even and inexact rounding",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xBEAAAAAB_3F801800_3F803000_3F802000,
        },
        .{ .qd = 0xB5552222_3C014444_3C026666_3C018888, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f16.f32 subnormal results raise ufc only when inexact",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x358637BD_32FFFAE5_33800000_38800000,
        },
        .{ .qd = 0x00112222_00004444_00016666_04008888, .fpscr = 0x00040018, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f16.f32 nans to the default nan, infinity, a flushed denormal",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_7F800000_FF800001_7FC00123,
        },
        .{ .qd = 0x00002222_7C004444_7E006666_7E008888, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f16.f32 signed zero, large values, more overflow",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x4808B800_47FFE000_4788B800_80000000,
        },
        .{ .qd = 0x7C002222_7C004444_7C006666_80008888, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f32.f16 normals, max, subnormals, infinities",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFC007C00_840003FF_00017BFF_C1003C00,
        },
        .{ .qd = 0xFF800000_B8800000_33800000_C0200000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vcvtt.f32.f16 nans and zeros",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01,
        },
        .{ .qd = 0x7FC00000_3EAAA000_80000000_7FC00000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
};
