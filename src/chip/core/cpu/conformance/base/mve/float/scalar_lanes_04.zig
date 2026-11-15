//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vfmas.f16 against infinity",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x1E42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .rm = 0x17C00,
        },
        .{ .qd = 0x7E007C00_7C007C00_7C007E00_7E007E00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f16 against a subnormal",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x1E42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0x12340001,
        },
        .{ .qd = 0x7E0077FF_000188B0_C2003266_7E00FC00, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f16 with fz16 flushes subnormals",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .rm = 0x1,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x7E00FBFF_00000000_BC007E00_7E007E00, .fpscr = 0x000C0001, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f16 with fz16 flushes a subnormal scalar",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E62,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0x1,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x00008000_00000000_00000000_80000000, .fpscr = 0x000C0000, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .rm = 0x3E99999A,
            .fpscr = 0x03C40010,
        },
        .{ .qd = 0x43962666_3E99999A_3F4CCCCD_3FE66666, .fpscr = 0x03C40010, .vpr = 0x00000000 },
    ),
    vec(
        "vsub of a lane equal to rm gives +0",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x1F42,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x00000000_40200000_C0200000_40200000,
            .rm = 0x40200000,
        },
        .{ .qd = 0xC0200000_00000000_C0A00000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "qd equal to qn accumulates onto its own multiplier",
        .{ .hw1 = 0xEE3B, .hw2 = 0xAE44, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .rm = 0xBFC00000 },
        .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas with qd equal to qn squares each lane",
        .{ .hw1 = 0xEE37, .hw2 = 0x7E4C, .qd = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x3F800000 },
        .{ .qd = 0x3F800000_3F800000_3F800000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6 and lr at f16",
        .{
            .hw1 = 0xFE3D,
            .hw2 = 0xFE4E,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0x3C00,
            .lr = 15360,
        },
        .{ .qd = 0x3C007C00_3C00FC00_5CB43C00_3E004100, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};
