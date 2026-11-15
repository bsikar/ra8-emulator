//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vcmul_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps pair 1",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x0E04,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
            .vpr = 0x0088FF00,
        },
        .{ .qd = 0x7F800000_00000000_55556666_77778888, .fpscr = 0x00040008, .vpr = 0x0000FF00 },
    ),
    vec(
        "a predicated imaginary half runs the pair but only its own flags count",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x0E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
            .vpr = 0x0088F0F0,
        },
        .{ .qd = 0x80000000_33334444_00000000_77778888, .fpscr = 0x00040080, .vpr = 0x0000F0F0 },
    ),
    vec(
        "only the real half of each f16 pair predicated",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x1E04,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .vpr = 0x00883333,
        },
        .{ .qd = 0x1111FC00_33338008_55557E00_7777FC00, .fpscr = 0x00040014, .vpr = 0x00003333 },
    ),
    vec(
        "the loop tail on 16-bit lanes stops after lane 2",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x1E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x11112222_33334444_5555CD40_4600BC00, .fpscr = 0x00010000, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x0E04,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
            .it = 0x20,
        },
        .{ .qd = 0x7F800000_7FC00000_55556666_77778888, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1a2 runs only beat 3",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x0E05,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .it = 0x40,
        },
        .{ .qd = 0x2C198011_33334444_55556666_77778888, .fpscr = 0x00040018, .vpr = 0x00000000 },
    ),
};
