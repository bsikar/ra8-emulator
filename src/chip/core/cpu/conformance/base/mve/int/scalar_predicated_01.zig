//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt p0 0x00ff keeps qd above",
        .{
            .hw1 = 0xEE23,
            .hw2 = 0x0F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
            .vpr = 0x008800FF,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_80000001_80000000, .vpr = 0x000000FF },
    ),
    vec(
        "saturation in an inactive lane leaves qc",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
            .vpr = 0x0088FF00,
        },
        .{ .qd = 0x00000004_00000000_01234567_89ABCDEF, .vpr = 0x0000FF00 },
    ),
    vec(
        "saturation in an active lane sets qc",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
            .vpr = 0x008800FF,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_80000001_7FFFFFFF, .vpr = 0x000000FF, .qc = 1 },
    ),
    vec(
        "qc already set stays set",
        .{
            .hw1 = 0xFE22,
            .hw2 = 0x0F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000004_00000003_00000002_00000001,
            .rm = 0x5,
            .qc = 1,
        },
        .{ .qd = 0x00000009_00000008_00000007_00000006, .qc = 1 },
    ),
    vec(
        "the loop tail stops vqadd qc",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0F62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF,
            .rm = 0x1,
            .ltpsize = 2,
            .lr = 0,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF },
    ),
    vec(
        "the loop tail writes the first lanes",
        .{
            .hw1 = 0xEE13,
            .hw2 = 0x0F42,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x1,
            .ltpsize = 1,
            .lr = 3,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01230000_80018000 },
    ),
    vec(
        "eci a0 skips beat 0",
        .{
            .hw1 = 0xEE03,
            .hw2 = 0x1E62,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x3,
            .it = 0x10,
        },
        .{ .qd = 0xFA06B483_7AFEFF00_D03040C0_89ABCDEF },
    ),
};
