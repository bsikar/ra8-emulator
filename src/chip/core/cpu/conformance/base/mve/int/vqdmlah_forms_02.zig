//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vqdmlah_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vqdmlash.s32 by a small scalar",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x1E62,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x3,
        },
        .{ .qda = 0xEED8ED1D_00000002_7FFFFFFF_00000003, .qc = 1 },
    ),
    vec(
        "vqrdmlash.s8",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x1E42,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x80,
        },
        .{ .qda = 0x8080BCFE_83D68080_808280A0_80800081, .qc = 1 },
    ),
    vec(
        "vqrdmlash.s8 by a small scalar",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x1E42,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0x03033F7F_0659AE03_0105E323_03037F04, .qc = 1 },
    ),
    vec(
        "vqrdmlash.s16",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x1E42,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x4000,
        },
        .{ .qda = 0x52354C4C_20006000_40004000_7FFF4001, .qc = 1 },
    ),
    vec(
        "vqrdmlash.s16 by a small scalar",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x1E42,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0x11380B4F_DF031F03_FF03FF03_7F03FF04 },
    ),
    vec(
        "vqrdmlash.s32",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x1E42,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x80000000,
        },
        .{ .qda = 0x80000000_80000000_00000000_80000001, .qc = 1 },
    ),
    vec(
        "vqrdmlash.s32 by a small scalar",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x1E42,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x3,
        },
        .{ .qda = 0xEED8ED1E_00000003_7FFFFFFF_00000004, .qc = 1 },
    ),
    vec(
        "vqdmlah.s16 q7, q6, r12",
        .{
            .hw1 = 0xEE1C,
            .hw2 = 0xEE6C,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x7FFF,
        },
        .{ .qda = 0x800068AB_00007FFF_FFFF0001_80007FFF, .qc = 1 },
    ),
    vec(
        "vqrdmlash.s32 qda = qn, lr",
        .{ .hw1 = 0xEE26, .hw2 = 0x7E4E, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1234 },
        .{ .qda = 0x0296DFEC_00001234_7FFFFFFF_7FFFFFFF, .qc = 1 },
    ),
    vec(
        "no saturation leaves qc",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E62,
            .qda = 0x00000004_00000003_00000002_00000001,
            .qn = 0x00000004_00000003_00000002_00000001,
            .rm = 0x5,
        },
        .{ .qda = 0x00000004_00000003_00000002_00000001 },
    ),
    vec(
        "qc already set stays set",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E62,
            .qda = 0x00000004_00000003_00000002_00000001,
            .qn = 0x00000004_00000003_00000002_00000001,
            .rm = 0x5,
            .qc = 1,
        },
        .{ .qda = 0x00000004_00000003_00000002_00000001, .qc = 1 },
    ),
};
