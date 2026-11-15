//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("pair_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vhadd.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0044,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFE005D81_4095EA19_00100040_00008040 },
    ),
    vec(
        "vhadd.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0044,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFE805D81_40956A19_80108040_80808040 },
    ),
    vec(
        "vhadd.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0044,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xB6E53456_00004000_00000000_80004000 },
    ),
    vec(
        "vhadd.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0044,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xB6E53456_80004000_80008000_80004000 },
    ),
    vec(
        "vhadd.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0044,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0xCCCCCCCC_00000000_80000000_40000000 },
    ),
    vec(
        "vhadd.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0044,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x4CCCCCCC_80000000_80000000_40000000 },
    ),
    vec(
        "vrhadd.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0144,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFE015E81_4195EB1A_01100040_00018040 },
    ),
    vec(
        "vrhadd.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0144,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0xFE815E81_41956B1A_81108040_80818040 },
    ),
    vec(
        "vrhadd.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0144,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xB6E63456_00004000_00000001_80004000 },
    ),
    vec(
        "vrhadd.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0144,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xB6E63456_80004000_80008001_80004000 },
    ),
    vec(
        "vrhadd.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0144,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0xCCCCCCCD_00000001_80000000_40000000 },
    ),
    vec(
        "vrhadd.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0144,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x4CCCCCCD_80000001_80000000_40000000 },
    ),
    vec(
        "vhsub.s8",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0244,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0x0001DE00_3D156AE6_EF00C000_01FE003F },
    ),
    vec(
        "vhsub.u8",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0244,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
        },
        .{ .qd = 0x0081DE00_3D15EAE6_6F004000_817E003F },
    ),
    vec(
        "vhsub.s16",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0244,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x36E5DDDE_C0000000_0001FFFE_00003FFF },
    ),
    vec(
        "vhsub.u16",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0244,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0x36E5DDDE_40000000_80017FFE_00003FFF },
    ),
    vec(
        "vhsub.s32",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0244,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0x456789AB_FFFFFFFE_00000000_3FFFFFFF },
    ),
    vec(
        "vhsub.u32",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0244,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
        },
        .{ .qd = 0xC56789AB_7FFFFFFE_00000000_3FFFFFFF },
    ),
};
