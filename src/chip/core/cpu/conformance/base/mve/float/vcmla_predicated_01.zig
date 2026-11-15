//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vcmla_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps pair 1",
        .{
            .hw1 = 0xFC32,
            .hw2 = 0x0844,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
            .vpr = 0x0088FF00,
        },
        .{ .qd = 0x7FC00000_00000000_80000000_00000000, .fpscr = 0x00040089, .vpr = 0x0000FF00 },
    ),
    vec(
        "a predicated imaginary half runs the pair but only its own flags count",
        .{
            .hw1 = 0xFCB2,
            .hw2 = 0x0844,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
            .vpr = 0x0088F0F0,
        },
        .{ .qd = 0xFF800000_7FC00000_7F800000_3F800000, .fpscr = 0x00040014, .vpr = 0x0000F0F0 },
    ),
    vec(
        "only the real half of each f16 pair predicated",
        .{
            .hw1 = 0xFD22,
            .hw2 = 0x0844,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .vpr = 0x00883333,
        },
        .{ .qd = 0x7C01FC00_00008010_BC007E00_7E00FC00, .fpscr = 0x00040014, .vpr = 0x00003333 },
    ),
    vec(
        "the loop tail on 16-bit lanes stops after lane 2",
        .{
            .hw1 = 0xFDA2,
            .hw2 = 0x0844,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x8000FC00_0002FB53_5640CD40_45C00000, .fpscr = 0x00010010, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xFC32,
            .hw2 = 0x0844,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
            .it = 0x20,
        },
        .{ .qd = 0x7FC00000_7FC00000_3F800000_3F800000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1a2 runs only beat 3",
        .{
            .hw1 = 0xFCA2,
            .hw2 = 0x0844,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .it = 0x40,
        },
        .{ .qd = 0x7E00FBFF_00008008_BC004000_7E00FC00, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
};
