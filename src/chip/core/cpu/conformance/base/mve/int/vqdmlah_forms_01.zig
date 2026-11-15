//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vqdmlah_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vqdmlah.s8",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x0E62,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x80,
        },
        .{ .qda = 0x00FD4300_85D68033_21007F00_FE030082, .qc = 1 },
    ),
    vec(
        "vqdmlah.s8 by a small scalar",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x0E62,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0xFDFF7F80_05808133_10103E41_FF018003, .qc = 1 },
    ),
    vec(
        "vqdmlah.s16",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x0E62,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x4000,
        },
        .{ .qda = 0x80005F92_20006000_FFFF0001_80004000, .qc = 1 },
    ),
    vec(
        "vqdmlah.s16 by a small scalar",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x0E62,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0x80235654_407E3F81_FFFE0002_80FDFF04 },
    ),
    vec(
        "vqdmlah.s32",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E62,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x80000000,
        },
        .{ .qda = 0x80000000_00000003_00000000_80000002, .qc = 1 },
    ),
    vec(
        "vqdmlah.s32 by a small scalar",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E62,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x3,
        },
        .{ .qda = 0x87654321_00000001_80000000_00000003, .qc = 1 },
    ),
    vec(
        "vqrdmlah.s8",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x0E42,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x80,
        },
        .{ .qda = 0x00FD4300_85D68033_21007F00_FE030082, .qc = 1 },
    ),
    vec(
        "vqrdmlah.s8 by a small scalar",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x0E42,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0xFEFF7F80_06808233_11103F42_FF028004, .qc = 1 },
    ),
    vec(
        "vqrdmlah.s16",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x0E42,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x4000,
        },
        .{ .qda = 0x80005F92_20006000_00000002_80004001, .qc = 1 },
    ),
    vec(
        "vqrdmlah.s16 by a small scalar",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x0E42,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0x80245654_407F3F82_FFFF0002_80FDFF04 },
    ),
    vec(
        "vqrdmlah.s32",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E42,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x80000000,
        },
        .{ .qda = 0x80000000_00000003_00000000_80000002, .qc = 1 },
    ),
    vec(
        "vqrdmlah.s32 by a small scalar",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E42,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x3,
        },
        .{ .qda = 0x87654321_00000002_80000000_00000004, .qc = 1 },
    ),
    vec(
        "vqdmlash.s8",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x1E62,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x80,
        },
        .{ .qda = 0x8080BBFE_82D68080_808280A0_80800080, .qc = 1 },
    ),
    vec(
        "vqdmlash.s8 by a small scalar",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x1E62,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0x03023E7F_0559AE03_0005E323_02027F03, .qc = 1 },
    ),
    vec(
        "vqdmlash.s16",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x1E62,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x4000,
        },
        .{ .qda = 0x52354C4C_20006000_3FFF3FFF_7FFF4000, .qc = 1 },
    ),
    vec(
        "vqdmlash.s16 by a small scalar",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x1E62,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0xFFFFFF03,
        },
        .{ .qda = 0x11380B4F_DF031F03_FF02FF02_7F03FF03 },
    ),
    vec(
        "vqdmlash.s32",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x1E62,
            .qda = 0x87654321_00000002_80000000_00000001,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x80000000,
        },
        .{ .qda = 0x80000000_80000000_00000000_80000000, .qc = 1 },
    ),
};
