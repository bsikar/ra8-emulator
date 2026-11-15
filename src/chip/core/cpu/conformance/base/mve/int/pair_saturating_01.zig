//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("pair_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vqadd.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFC017F80_7F80D533_0120007F_0001807F, .qc = 1 },
    ),
    vec(
        "vqadd.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFFFFBBFF_81FFD533_FF20FF80_FFFFFF80, .qc = 1 },
    ),
    vec(
        "vqadd.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x800068AC_00007FFF_00000001_80007FFF, .qc = 1 },
    ),
    vec(
        "vqadd.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xFFFF68AC_FFFF8000_FFFFFFFF_FFFF8000, .qc = 1 },
    ),
    vec(
        "vqadd.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x99999999_00000001_80000000_7FFFFFFF, .qc = 1 },
    ),
    vec(
        "vqadd.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x99999999_FFFFFFFF_FFFFFFFF_80000000, .qc = 1 },
    ),
    vec(
        "vqsub.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0254,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0x0003BD00_7B2A7FCD_DF008000_02FD007E, .qc = 1 },
    ),
    vec(
        "vqsub.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0254,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0x00000000_7B2A0000_DF008000_00FD007E, .qc = 1 },
    ),
    vec(
        "vqsub.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0254,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x6DCBBBBC_80000000_0002FFFD_00007FFE },
    ),
    vec(
        "vqsub.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0254,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x6DCB0000_80000000_0000FFFD_00007FFE, .qc = 1 },
    ),
    vec(
        "vqsub.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0254,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x7FFFFFFF_FFFFFFFD_00000000_7FFFFFFE, .qc = 1 },
    ),
    vec(
        "vqsub.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0254,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x00000000_FFFFFFFD_00000000_7FFFFFFE, .qc = 1 },
    ),
    vec(
        "vqadd without saturation leaves qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000004_00000003_00000002_00000001,
            .qm = 0x00000008_00000007_00000006_00000005,
        },
        .{ .qd = 0x0000000C_0000000A_00000008_00000006 },
    ),
    vec(
        "qc already set stays set",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000004_00000003_00000002_00000001,
            .qm = 0x00000008_00000007_00000006_00000005,
            .qc = 1,
        },
        .{ .qd = 0x0000000C_0000000A_00000008_00000006, .qc = 1 },
    ),
};
