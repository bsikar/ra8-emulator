//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("half_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps lanes 1 and 3 of a narrow",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_7F800000_FF800001_7FC00123,
            .vpr = 0x00880F0F,
        },
        .{ .qd = 0x11112222_33337C00_55556666_77777E00, .fpscr = 0x00040000, .vpr = 0x00000F0F },
    ),
    vec(
        "vcvtt narrow with only the upper half bytes predicated drops the lane flags",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_7F800000_FF800001_7FC00123,
            .vpr = 0x0088CCCC,
        },
        .{ .qd = 0x00002222_7C004444_7E006666_7E008888, .fpscr = 0x00040000, .vpr = 0x0000CCCC },
    ),
    vec(
        "vcvtt widen counts flags from byte 2",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01,
            .vpr = 0x00884444,
        },
        .{ .qd = 0x11C02222_33AA4444_55006666_77C08888, .fpscr = 0x00040001, .vpr = 0x00004444 },
    ),
    vec(
        "vcvtb widen with byte 0 off drops the lane flags",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01,
            .vpr = 0x0088EEEE,
        },
        .{ .qd = 0x7FC00022_00000044_7FC00066_7FC00088, .fpscr = 0x00040000, .vpr = 0x0000EEEE },
    ),
    vec(
        "the loop tail stops after lane 1",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x00000123_7F800000_FF800001_7FC00123,
            .lr = 2,
            .fpscr = 0x00020000,
        },
        .{ .qd = 0x11112222_33334444_55557E00_77777E00, .fpscr = 0x00020001, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xFE3F,
            .hw2 = 0x1E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01,
            .it = 0x20,
        },
        .{ .qd = 0x7FC00000_3EAAA000_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1a2 runs only beat 3",
        .{
            .hw1 = 0xEE3F,
            .hw2 = 0x0E03,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qm = 0x477FF000_477FE000_C0200000_3F800000,
            .it = 0x40,
        },
        .{ .qd = 0x11117C00_33334444_55556666_77778888, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};
