//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vqadd.s8 saturates both ways",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x0F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x40,
        },
        .{ .qd = 0x3E427CC1_7FEA7F40_3050007F_413FC07F, .qc = 1 },
    ),
    vec(
        "vqadd.u16 saturates at 0xffff",
        .{
            .hw1 = 0xFE12,
            .hw2 = 0x0F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x8000,
        },
        .{ .qd = 0xFFFF9234_FFFFC000_8001FFFF_FFFFFFFF, .qc = 1 },
    ),
    vec(
        "vqadd.u32 without saturation",
        .{
            .hw1 = 0xFE22,
            .hw2 = 0x0F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000004_00000003_00000002_00000001,
            .rm = 0x5,
        },
        .{ .qd = 0x00000009_00000008_00000007_00000006 },
    ),
    vec(
        "vqsub.s32 saturates",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x1F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
        },
        .{ .qd = 0x00000002_FFFFFFFE_80000000_7FFFFFFE, .qc = 1 },
    ),
    vec(
        "vqsub.u8 floors at zero",
        .{
            .hw1 = 0xFE02,
            .hw2 = 0x1F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x10,
        },
        .{ .qd = 0xEE002C71_6E9A4500_E000B030_00EF706F, .qc = 1 },
    ),
    vec(
        "vhadd.s8 halves toward minus infinity",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x0F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0xFF,
        },
        .{ .qd = 0xFE001DC0_3ED42AFF_F707DF1F_00FFBF3F },
    ),
    vec(
        "vhadd.u32 keeps the carry",
        .{
            .hw1 = 0xFE22,
            .hw2 = 0x0F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0xFFFFFFFF,
        },
        .{ .qd = 0x80000001_FFFFFFFF_BFFFFFFF_BFFFFFFF },
    ),
    vec(
        "vhsub.s16",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x1F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x7FFF,
        },
        .{ .qd = 0xB6E6C91A_A000E000_C001C000_80000000 },
    ),
    vec(
        "vhsub.u8",
        .{
            .hw1 = 0xFE02,
            .hw2 = 0x1F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x80,
        },
        .{ .qd = 0x3FC1DE00_FF15EAC0_38C820E0_C03F00FF },
    ),
    vec(
        "vadd.i16 q7, q6, r12",
        .{
            .hw1 = 0xEE1D,
            .hw2 = 0xEF4C,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x7,
        },
        .{ .qd = 0xEDD2123B_C0074007_00080006_80078006 },
    ),
    vec(
        "qd = qn",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x2F4E,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
        },
        .{ .qd = 0x00000004_00000000_80000001_80000000 },
    ),
};
