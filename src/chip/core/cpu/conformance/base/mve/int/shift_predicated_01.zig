//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("shift_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt p0 0x0ff0 merges the middle",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
            .vpr = 0x00880FF0,
        },
        .{ .qd = 0xDEADBEEF_F0000001_00008000_89ABCDEF, .vpr = 0x00000FF0 },
    ),
    vec(
        "saturation only in an inactive lane leaves qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000001_00000001_00000001_00000004,
            .qm = 0x00000003_00000002_00000001_40000000,
            .vpr = 0x0088FFF0,
        },
        .{ .qd = 0x00000006_00000004_00000002_89ABCDEF, .vpr = 0x0000FFF0 },
    ),
    vec(
        "saturation in an active lane sets qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000001_00000001_00000001_00000004,
            .qm = 0x00000003_00000002_00000001_40000000,
            .vpr = 0x0088000F,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_7FFFFFFF, .vpr = 0x0000000F, .qc = 1 },
    ),
    vec(
        "the loop tail stops vqrshl qc",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0554,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000001_00000001_00000008_00000001,
            .qm = 0x00000003_00000002_FFFFFFFF_00000001,
            .ltpsize = 2,
            .lr = 1,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_00000002 },
    ),
    vec(
        "the loop tail writes the first lanes",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0444,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101,
            .qm = 0xFF02AA00_7E038155_F011C040_01FF807F,
            .ltpsize = 0,
            .lr = 7,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_0104E000_80FE00FE },
    ),
    vec(
        "eci a0a1 keeps the done beats",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0544,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00F00004_00FE00F1_0110000F_00FF0001,
            .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF,
            .it = 0x20,
        },
        .{ .qd = 0x00012340_30000001_01234567_89ABCDEF },
    ),
};
