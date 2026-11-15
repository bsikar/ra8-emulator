//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("mulh_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vqdmulh.s8 saturates the minimum squared",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF02807F,
        },
        .{ .qd = 0x00FF3B7E_0256AB00_FD02E020_FFFF7F7E, .qc = 1 },
    ),
    vec(
        "vqrdmulh.s8 rounds",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF02807F,
        },
        .{ .qd = 0x00003C7E_0356AB00_FE02E020_00007F7E, .qc = 1 },
    ),
    vec(
        "vqdmulh.s16 saturates the minimum squared",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80007FFF,
        },
        .{ .qd = 0x12350C4C_E0002000_FFFFFFFF_7FFF7FFE, .qc = 1 },
    ),
    vec(
        "vqrdmulh.s16 rounds",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80007FFF,
        },
        .{ .qd = 0x12350C4C_E0002000_00000000_7FFF7FFE, .qc = 1 },
    ),
    vec(
        "vqdmulh.s32 saturates the minimum squared",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
        },
        .{ .qd = 0xEED8ED1A_FFFFFFFF_7FFFFFFF_7FFFFFFE, .qc = 1 },
    ),
    vec(
        "vqrdmulh.s32 rounds",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
        },
        .{ .qd = 0xEED8ED1B_00000000_7FFFFFFF_7FFFFFFE, .qc = 1 },
    ),
    vec(
        "vqdmulh without saturation leaves qc",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00080007_00060005_00040003_00020001,
            .qm = 0x40004000_40004000_40004000_40004000,
        },
        .{ .qd = 0x00040003_00030002_00020001_00010000 },
    ),
    vec(
        "qc already set stays set",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00080007_00060005_00040003_00020001,
            .qm = 0x40004000_40004000_40004000_40004000,
            .qc = 1,
        },
        .{ .qd = 0x00040003_00030002_00020001_00010000, .qc = 1 },
    ),
};
