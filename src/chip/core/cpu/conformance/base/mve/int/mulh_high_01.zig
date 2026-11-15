//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("mulh_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vmulh.s8",
        .{
            .hw1 = 0xEE03,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF02807F,
        },
        .{ .qd = 0x00FF1D3F_012BD500_FE01F010_FFFF403F },
    ),
    vec(
        "vmulh.u8",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF02807F,
        },
        .{ .qd = 0xFC011D41_01552A00_0F013010_0001403F },
    ),
    vec(
        "vrmulh.s8",
        .{
            .hw1 = 0xEE03,
            .hw2 = 0x1E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF02807F,
        },
        .{ .qd = 0x00001E3F_012BD600_FF01F010_0000403F },
    ),
    vec(
        "vrmulh.u8",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF02807F,
        },
        .{ .qd = 0xFC021E41_01552B00_10013010_0102403F },
    ),
    vec(
        "vmulh.s16",
        .{
            .hw1 = 0xEE13,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80007FFF,
        },
        .{ .qd = 0x091A0626_F0001000_FFFFFFFF_40003FFF },
    ),
    vec(
        "vmulh.u16",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80007FFF,
        },
        .{ .qd = 0x76E50626_30001000_00000001_40003FFF },
    ),
    vec(
        "vrmulh.s16",
        .{
            .hw1 = 0xEE13,
            .hw2 = 0x1E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80007FFF,
        },
        .{ .qd = 0x091B0626_F0001000_00000000_40003FFF },
    ),
    vec(
        "vrmulh.u16",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x1E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80007FFF,
        },
        .{ .qd = 0x76E60626_30001000_00010002_40003FFF },
    ),
    vec(
        "vmulh.s32",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
        },
        .{ .qd = 0xF76C768D_FFFFFFFF_40000000_3FFFFFFF },
    ),
    vec(
        "vmulh.u32",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
        },
        .{ .qd = 0x09A0CD05_00000001_40000000_3FFFFFFF },
    ),
    vec(
        "vrmulh.s32",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x1E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
        },
        .{ .qd = 0xF76C768D_00000000_40000000_3FFFFFFF },
    ),
    vec(
        "vrmulh.u32",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x1E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
        },
        .{ .qd = 0x09A0CD05_00000002_40000000_3FFFFFFF },
    ),
    vec(
        "vmulh.s32 q7, q6, q5",
        .{
            .hw1 = 0xEE2D,
            .hw2 = 0xEE0B,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
        },
        .{ .qd = 0xF76C768D_FFFFFFFF_40000000_3FFFFFFF },
    ),
    vec(
        "qd = qn = qm squares",
        .{
            .hw1 = 0xEE17,
            .hw2 = 0x7E07,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000 },
    ),
};
