//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps lanes 2 and 3",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
            .vpr = 0x0088FF00,
        },
        .{ .qd = 0x7F800000_1EBCE508_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x0000FF00 },
    ),
    vec(
        "a lane predicated past its first byte runs without its flags",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0D54,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
            .vpr = 0x0088E0E0,
        },
        .{ .qd = 0x00000022_33334444_BF800066_77778888, .fpscr = 0x00040000, .vpr = 0x0000E0E0 },
    ),
    vec(
        "odd f16 lanes predicated",
        .{
            .hw1 = 0xFF32,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .vpr = 0x0088CCCC,
        },
        .{ .qd = 0x00002222_44004444_7E006666_3C008888, .fpscr = 0x00040001, .vpr = 0x0000CCCC },
    ),
    vec(
        "the loop tail on 16-bit lanes stops after lane 2",
        .{
            .hw1 = 0xEF32,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x11112222_33334444_5555B267_C100BE00, .fpscr = 0x00010000, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
            .it = 0x20,
        },
        .{ .qd = 0xBF800000_7F800000_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1a2 runs only beat 3",
        .{
            .hw1 = 0xFF12,
            .hw2 = 0x0D54,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .it = 0x40,
        },
        .{ .qd = 0x00117C00_33334444_55556666_77778888, .fpscr = 0x0004001C, .vpr = 0x00000000 },
    ),
};
