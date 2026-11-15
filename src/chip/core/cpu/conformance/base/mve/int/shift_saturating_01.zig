//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("shift_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vqshl.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF00FA00_7F01FF7F_FF04E07F_7FFE807F, .qc = 1 },
    ),
    vec(
        "vqshl.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF000A00_FF0101FF_000460FF_80FFFFFE, .qc = 1 },
    ),
    vec(
        "vqshl.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0xFFFF7FFF_F0000000_7FFF8000_C0007FFF, .qc = 1 },
    ),
    vec(
        "vqshl.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0x0000FFFF_30000000_FFFFFFFF_4000FFFE, .qc = 1 },
    ),
    vec(
        "vqshl.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0xFFFFFFFF_7FFFFFFF_C0000000_7FFFFFFF, .qc = 1 },
    ),
    vec(
        "vqshl.s32 (second set)",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_80000000_01234567, .qc = 1 },
    ),
    vec(
        "vqshl.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0x00000000_FFFFFFFF_40000000_FFFFFFFE, .qc = 1 },
    ),
    vec(
        "vqshl.u32 (second set)",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_FFFFFFFF_01234567, .qc = 1 },
    ),
    vec(
        "vqrshl.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF00FB00_7F02FF7F_0004E07F_7FFE807F, .qc = 1 },
    ),
    vec(
        "vqrshl.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF000B00_FF0201FF_000460FF_80FFFFFE, .qc = 1 },
    ),
    vec(
        "vqrshl.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0x00007FFF_F0000001_7FFF8000_C0007FFF, .qc = 1 },
    ),
    vec(
        "vqrshl.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0x0001FFFF_30000001_FFFFFFFF_4000FFFE, .qc = 1 },
    ),
    vec(
        "vqrshl.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0x00000000_7FFFFFFF_C0000001_7FFFFFFF, .qc = 1 },
    ),
    vec(
        "vqrshl.s32 (second set)",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_80000000_01234568, .qc = 1 },
    ),
    vec(
        "vqrshl.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0x00000001_FFFFFFFF_40000001_FFFFFFFE, .qc = 1 },
    ),
    vec(
        "vqrshl.u32 (second set)",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_FFFFFFFF_01234568, .qc = 1 },
    ),
    vec(
        "vqshl without saturation leaves qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000004_00000003_00000002_00000001,
            .qm = 0x00000004_00000003_00000002_00000001,
        },
        .{ .qd = 0x00000040_00000018_00000008_00000002 },
    ),
};
