//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vcadd_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps lanes 1 and 3",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_7FC00001_7F800000_7F800000,
            .qm = 0x7F800001_00000000_7F800000_7F800000,
            .vpr = 0x0088F0F0,
        },
        .{ .qd = 0x00000000_33334444_7F800000_77778888, .fpscr = 0x00040000, .vpr = 0x0000F0F0 },
    ),
    vec(
        "a lane with byte 0 off is written but its flags drop",
        .{
            .hw1 = 0xFD92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6,
            .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6,
            .vpr = 0x0088EEEE,
        },
        .{ .qd = 0x00000022_3F800044_FF800066_7F800088, .fpscr = 0x00040000, .vpr = 0x0000EEEE },
    ),
    vec(
        "f16 lanes count flags from their low byte",
        .{
            .hw1 = 0xFC82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80006800_80000010_00017E01_7C007C00,
            .qm = 0x00003C00_00040008_3C007C01_7C007C00,
            .vpr = 0x0088AAAA,
        },
        .{ .qd = 0x3C116822_00330044_7E557E66_7C777E88, .fpscr = 0x00040000, .vpr = 0x0000AAAA },
    ),
    vec(
        "the loop tail on 16-bit lanes stops after lane 2",
        .{
            .hw1 = 0xFD82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0xBC007BFF_14195640_3400C300_40003C00,
            .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x11112222_33334444_5555C100_3E00C200, .fpscr = 0x00010000, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6,
            .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6,
            .it = 0x20,
        },
        .{ .qd = 0x00000000_3F800000_55556666_77778888, .fpscr = 0x00040080, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1a2 runs only beat 3",
        .{
            .hw1 = 0xFC82,
            .hw2 = 0x0844,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80006800_80000010_00017E01_7C007C00,
            .qm = 0x00003C00_00040008_3C007C01_7C007C00,
            .it = 0x40,
        },
        .{ .qd = 0x3C006800_33334444_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
};
