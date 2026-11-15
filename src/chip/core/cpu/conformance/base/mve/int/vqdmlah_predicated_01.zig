//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vqdmlah_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt p0 0x00ff merges the low half",
        .{
            .hw1 = 0xEE12,
            .hw2 = 0x0E42,
            .qda = 0x80005678_40004000_FFFF0002_80000001,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .rm = 0x4000,
            .vpr = 0x008800FF,
        },
        .{ .qda = 0x80005678_40004000_00000002_80004001, .vpr = 0x000000FF, .qc = 1 },
    ),
    vec(
        "saturation only in an inactive lane leaves qc",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E62,
            .qda = 0x00000004_00000003_00000002_00000001,
            .qn = 0x00000003_00000002_00000001_80000000,
            .rm = 0x80000000,
            .vpr = 0x0088FFF0,
        },
        .{ .qda = 0x00000001_00000001_00000001_00000001, .vpr = 0x0000FFF0 },
    ),
    vec(
        "saturation in an active lane sets qc",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E62,
            .qda = 0x00000004_00000003_00000002_00000001,
            .qn = 0x00000003_00000002_00000001_80000000,
            .rm = 0x80000000,
            .vpr = 0x0088000F,
        },
        .{ .qda = 0x00000004_00000003_00000002_7FFFFFFF, .vpr = 0x0000000F, .qc = 1 },
    ),
    vec(
        "the loop tail stops qc",
        .{
            .hw1 = 0xEE22,
            .hw2 = 0x0E62,
            .qda = 0x00000004_00000003_00000002_00000001,
            .qn = 0x00000003_00000002_80000000_00000001,
            .rm = 0x80000000,
            .ltpsize = 2,
            .lr = 1,
        },
        .{ .qda = 0x00000004_00000003_00000002_00000000 },
    ),
    vec(
        "eci a0a1 keeps the done beats",
        .{
            .hw1 = 0xEE02,
            .hw2 = 0x1E62,
            .qda = 0xFEFF7F81_03808033_11104040_FF028001,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
            .rm = 0x40,
            .it = 0x20,
        },
        .{ .qda = 0x403F7B7F_427FEB40_11104040_FF028001, .qc = 1 },
    ),
};
