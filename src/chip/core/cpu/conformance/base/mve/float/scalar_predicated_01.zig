//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps lanes 2 and 3",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .rm = 0x40000000,
            .vpr = 0x0088FF00,
        },
        .{ .qd = 0x7FC00000_1EBCE508_80000000_00000000, .fpscr = 0x00040081, .vpr = 0x0000FF00 },
    ),
    vec(
        "a lane predicated past its first byte runs without its flags",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x501502F9,
            .vpr = 0x0088E0E0,
        },
        .{ .qd = 0x00000000_7FC00000_7F800000_3F800000, .fpscr = 0x00040000, .vpr = 0x0000E0E0 },
    ),
    vec(
        "odd f16 lanes predicated",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x0F42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .rm = 0x7C00,
            .vpr = 0x0088CCCC,
        },
        .{ .qd = 0x7C00FBFF_7C008008_7C004000_7C00FC00, .fpscr = 0x00040000, .vpr = 0x0000CCCC },
    ),
    vec(
        "the loop tail on 16-bit lanes stops after lane 2",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x1F42,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0x4200,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .qd = 0x8000FC00_0002FB53_5640C1CD_C500BE00, .fpscr = 0x00010010, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1 leaves the done beats alone",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x501502F9,
            .it = 0x20,
        },
        .{ .qd = 0x7FC00000_7FC00000_3F800000_3F800000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "eci a0a1a2 runs only beat 3",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E62,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .rm = 0x1,
            .it = 0x40,
        },
        .{ .qd = 0x00000400_00008008_BC004000_7E00FC00, .fpscr = 0x00040018, .vpr = 0x00000000 },
    ),
};
