//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("shift_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vshl.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF00FA00_F801FF00_FF04E000_80FE00FE },
    ),
    vec(
        "vshl.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF000A00_F8010100_00046000_80FE00FE },
    ),
    vec(
        "vshl.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0xFFFF2340_F0000000_00008000_C000FFFE },
    ),
    vec(
        "vshl.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0x00002340_30000000_00008000_4000FFFE },
    ),
    vec(
        "vshl.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0xFFFFFFFF_80000000_C0000000_FFFFFFFE },
    ),
    vec(
        "vshl.s32 (second set)",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_00000000_01234567 },
    ),
    vec(
        "vshl.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0x00000000_80000000_40000000_FFFFFFFE },
    ),
    vec(
        "vshl.u32 (second set)",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_00000000_01234567 },
    ),
    vec(
        "vrshl.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF00FB00_F802FF00_0004E000_80FE00FE },
    ),
    vec(
        "vrshl.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
        },
        .{ .qd = 0xFF000B00_F8020100_00046000_80FE00FE },
    ),
    vec(
        "vrshl.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0x00002340_F0000001_00008000_C000FFFE },
    ),
    vec(
        "vrshl.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0x00012340_30000001_00008000_4000FFFE },
    ),
    vec(
        "vrshl.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0x00000000_80000000_C0000001_FFFFFFFE },
    ),
    vec(
        "vrshl.s32 (second set)",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_00000000_01234568 },
    ),
    vec(
        "vrshl.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x000000E0_0000001F_000000FF_00000001,
            .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF,
        },
        .{ .qd = 0x00000001_80000000_40000001_FFFFFFFE },
    ),
    vec(
        "vrshl.u32 (second set)",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000081_12345602_00000020_FFFFFFFC,
            .qm = 0x40000000_00000001_87654321_12345678,
        },
        .{ .qd = 0x00000000_00000004_00000000_01234568 },
    ),
    vec(
        "vshl.s16 q7, q5, q6",
        .{
            .hw1 = 0xEF1C,
            .hw2 = 0xE44A,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
        },
        .{ .qd = 0xFFFF2340_F0000000_00008000_C000FFFE },
    ),
    vec(
        "vshl with qm = qn shifts each lane by itself",
        .{
            .hw1 = 0xFF06,
            .hw2 = 0x0446,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x1110097F_80F8FEFF_07060504_03020100,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000 },
    ),
};
