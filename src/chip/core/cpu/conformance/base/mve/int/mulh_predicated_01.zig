//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("mulh_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt p0 0x00ff merges the low half",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_7FFFFFFF,
            .vpr = 0x008800FF,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_40000000_3FFFFFFF, .vpr = 0x000000FF },
    ),
    vec(
        "saturation only in an inactive lane leaves qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_00000002_00000001_80000000,
            .qm = 0x00000003_00000002_00000001_80000000,
            .vpr = 0x0088FF00,
        },
        .{ .qd = 0x00000000_00000000_01234567_89ABCDEF, .vpr = 0x0000FF00 },
    ),
    vec(
        "saturation in an active lane sets qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_00000002_00000001_80000000,
            .qm = 0x00000003_00000002_00000001_80000000,
            .vpr = 0x0088000F,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_7FFFFFFF, .vpr = 0x0000000F, .qc = 1 },
    ),
    vec(
        "the loop tail writes the first lanes",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x1E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80007FFF,
            .ltpsize = 1,
            .lr = 3,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01230002_40003FFF },
    ),
    vec(
        "the loop tail stops qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0B44,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_00000002_80000000_00000001,
            .qm = 0x00000003_00000002_80000000_00000001,
            .ltpsize = 2,
            .lr = 1,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_00000000 },
    ),
    vec(
        "eci a0a1a2 keeps three beats",
        .{
            .hw1 = 0xEE03,
            .hw2 = 0x0E05,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF02807F,
            .it = 0x40,
        },
        .{ .qd = 0x00FF1D3F_CAFEF00D_01234567_89ABCDEF },
    ),
};
