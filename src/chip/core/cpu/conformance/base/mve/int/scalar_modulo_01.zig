//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vadd.i8 wraps",
        .{
            .hw1 = 0xEE03,
            .hw2 = 0x0F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x181,
        },
        .{ .qd = 0x7F83BD02_FF2BD681_719141C1_82800100 },
    ),
    vec(
        "vadd.i32 q0, q1, r2",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x0F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
        },
        .{ .qd = 0x00000004_00000000_80000001_80000000 },
    ),
    vec(
        "vadd u set changes nothing",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x0F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
        },
        .{ .qd = 0x00000004_00000000_80000001_80000000 },
    ),
    vec(
        "vsub.i16 q0, q1, r2",
        .{
            .hw1 = 0xEE13,
            .hw2 = 0x1F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x20002,
        },
        .{ .qd = 0xEDC91232_BFFE3FFE_FFFFFFFD_7FFE7FFD },
    ),
    vec(
        "vmul.i32 wraps",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x1E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x3,
        },
        .{ .qd = 0x00000009_FFFFFFFD_80000000_7FFFFFFD },
    ),
    vec(
        "vmul.i8 by the low byte",
        .{
            .hw1 = 0xEE03,
            .hw2 = 0x1E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0xFF03,
        },
        .{ .qd = 0xFA06B483_7AFEFF00_D03040C0_03FD807D },
    ),
    vec(
        "vbrsr.8 keeps all 8 bits",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x8,
        },
        .{ .qd = 0x7F403C81_7E55AA00_0F080302_80FF01FE },
    ),
    vec(
        "vbrsr.16 keeps 5 bits",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x1E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x5,
        },
        .{ .qd = 0x001A0005_00000000_0010001F_0000001F },
    ),
    vec(
        "vbrsr.32 of zero bits is zero",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x1E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x100,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000 },
    ),
    vec(
        "vbrsr.32 past the width keeps all",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x1E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x28,
        },
        .{ .qd = 0xC0000000_FFFFFFFF_00000001_FFFFFFFE },
    ),
    vec(
        "vqdmulh.s16 0x8000 by 0x8000 saturates",
        .{
            .hw1 = 0xEE13,
            .hw2 = 0x0E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x8000,
        },
        .{ .qd = 0x1235EDCC_4000C000_FFFF0001_7FFF8001, .qc = 1 },
    ),
    vec(
        "vqdmulh.s32 by 2",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x0E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x40000000,
        },
        .{ .qd = 0x00000001_FFFFFFFF_C0000000_3FFFFFFF },
    ),
    vec(
        "vqrdmulh.s16 rounds",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x0E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x3FFF,
        },
        .{ .qd = 0xF6E6091A_E0012000_00000000_C0013FFF },
    ),
    vec(
        "vqrdmulh.s8 by -128 saturates",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x0E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x80,
        },
        .{ .qd = 0x02FEC47F_8256AB00_10F040C0_FF017F81, .qc = 1 },
    ),
};
