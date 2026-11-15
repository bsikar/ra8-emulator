//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vsub.f32 against the largest finite value",
        .{
            .hw1 = 0xEE32,
            .hw2 = 0x1F42,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .rm = 0x7F7FFFFF,
        },
        .{ .qd = 0xFF7FFFFF_FF7FFFFF_FF7FFFFF_FF7FFFFF, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f16 against 3.0 with junk in the high half of rm",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x1F42,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0xDEAD4200,
        },
        .{ .qd = 0xBC00C300_C1FB5CA4_0000C1CD_C500BE00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f16 against infinity",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x1F42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .rm = 0x17C00,
        },
        .{ .qd = 0xFC00FC00_FC00FC00_FC007E00_FC007E00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f16 against a subnormal",
        .{
            .hw1 = 0xFE32,
            .hw2 = 0x1F42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0x12340001,
        },
        .{ .qd = 0x4000B800_211F5CB0_42002E66_C0003E00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f32 against 3.0",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .rm = 0x40400000,
        },
        .{ .qd = 0x41100000_3E99999A_C0C00000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f32 against 1e10, with overflow and infinity times zero",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x501502F9,
        },
        .{ .qd = 0x00000000_7F800000_7F800000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f32 against a signalling nan",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .rm = 0x7F800001,
        },
        .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f32 against -0.0",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0x80000000_3F000000_C1000000_C0C00000,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .rm = 0x80000000,
        },
        .{ .qd = 0x00000000_80000000_80000000_80000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f32 against infinity",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x7F800000,
        },
        .{ .qd = 0x7FC00000_7F800000_7F800000_7F800000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f32 against a denormal, which reads as zero with idc",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .rm = 0x10,
        },
        .{ .qd = 0x00000000_00000000_80000000_00000000, .fpscr = 0x00040080, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f32 against the largest finite value",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E62,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .rm = 0x7F7FFFFF,
        },
        .{ .qd = 0x7F7FFFFF_7F800000_00000000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f16 against 3.0 with junk in the high half of rm",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E62,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0xDEAD4200,
        },
        .{ .qd = 0x4600BE00_27AE6308_488034CC_C6004480, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f16 against infinity",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E62,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .rm = 0x17C00,
        },
        .{ .qd = 0x7C007C00_7E007C00_7C007E00_7E007C00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vmul.f16 against a subnormal",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E62,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0x12340001,
        },
        .{ .qd = 0x00028000_0000012C_00030000_80020002, .fpscr = 0x00040018, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 against 3.0",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .rm = 0x40400000,
        },
        .{ .qd = 0x42DA0000_3E99999A_C0C80000_40B00000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 against 1e10, with overflow and infinity times zero",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x501502F9,
        },
        .{ .qd = 0xFF800000_7FC00000_7F800000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};
