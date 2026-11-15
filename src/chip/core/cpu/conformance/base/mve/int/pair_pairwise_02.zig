//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("pair_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vmax.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0644,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFE027F81_7EAA5533_11104040_0102807F },
    ),
    vec(
        "vmax.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0644,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFEFF7F81_7EAA8033_F010C040_FFFF807F },
    ),
    vec(
        "vmax.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0644,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xEDCB5678_40004000_00010002_80007FFF },
    ),
    vec(
        "vmax.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0644,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xEDCB5678_C0004000_FFFFFFFF_80007FFF },
    ),
    vec(
        "vmax.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0644,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x12345678_00000002_80000000_7FFFFFFF },
    ),
    vec(
        "vmax.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0644,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x87654321_FFFFFFFF_80000000_7FFFFFFF },
    ),
    vec(
        "vmin.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0654,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFEFF3C81_03808000_F010C040_FFFF8001 },
    ),
    vec(
        "vmin.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0654,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFE023C81_03805500_11104040_01028001 },
    ),
    vec(
        "vmin.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0654,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x80001234_C0004000_FFFFFFFF_80000001 },
    ),
    vec(
        "vmin.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0654,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x80001234_40004000_00010002_80000001 },
    ),
    vec(
        "vmin.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0654,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x87654321_FFFFFFFF_80000000_00000001 },
    ),
    vec(
        "vmin.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0654,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x12345678_00000002_80000000_00000001 },
    ),
    vec(
        "vabd.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0744,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0x00034300_7B2AD533_21008000_0203007E },
    ),
    vec(
        "vabd.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0744,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0x00FD4300_7B2A2B33_DF008000_FEFD007E },
    ),
    vec(
        "vabd.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0744,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x6DCB4444_80000000_00020003_00007FFE },
    ),
    vec(
        "vabd.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0744,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x6DCB4444_80000000_FFFEFFFD_00007FFE },
    ),
    vec(
        "vabd.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0744,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x8ACF1357_00000003_00000000_7FFFFFFE },
    ),
    vec(
        "vabd.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0744,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x7530ECA9_FFFFFFFD_00000000_7FFFFFFE },
    ),
};
