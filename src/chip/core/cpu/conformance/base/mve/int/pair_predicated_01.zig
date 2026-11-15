//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("pair_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt p0 0xff00 merges the high half",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0644,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
            .vpr = 0x0088FF00,
        },
        .{ .qd = 0xEDCB5678_40004000_01234567_89ABCDEF, .vpr = 0x0000FF00 },
    ),
    vec(
        "saturation only in an inactive lane leaves qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_00000002_00000001_7FFFFFFF,
            .qm = 0x00000003_00000002_00000001_7FFFFFFF,
            .vpr = 0x0088FFF0,
        },
        .{ .qd = 0x00000006_00000004_00000002_89ABCDEF, .vpr = 0x0000FFF0 },
    ),
    vec(
        "saturation in an active lane sets qc",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0054,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000003_00000002_00000001_7FFFFFFF,
            .qm = 0x00000003_00000002_00000001_7FFFFFFF,
            .vpr = 0x0088000F,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_7FFFFFFF, .vpr = 0x0000000F, .qc = 1 },
    ),
    vec(
        "the loop tail stops vqsub qc",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0254,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000000_00000000_00000000_00000005,
            .qm = 0x09090909_09090909_09090909_09090901,
            .ltpsize = 0,
            .lr = 1,
        },
        .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCD04 },
    ),
    vec(
        "the loop tail writes the first lanes",
        .{
            .hw1 = 0xFF22,
            .hw2 = 0x0744,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF,
            .qm = 0x87654321_00000002_80000000_00000001,
            .ltpsize = 2,
            .lr = 3,
        },
        .{ .qd = 0xDEADBEEF_FFFFFFFD_00000000_7FFFFFFE },
    ),
    vec(
        "eci a0 skips beat 0",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0144,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .qm = 0xFEFF7F81_03808033_11104040_FF028001,
            .it = 0x10,
        },
        .{ .qd = 0xFE015E81_4195EB1A_01100040_89ABCDEF },
    ),
};
