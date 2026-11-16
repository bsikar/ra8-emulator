//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fma_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vfma.f32 ordinary values and rounding",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0C54,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
        },
        .{ .qd = 0x429E0000_3CF5C296_BFA00000_40B00000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 overflow, infinities and infinity times zero with a qnan addend",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0C54,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
        },
        .{ .qd = 0xFF800000_7FC00000_B29C7F00_7F800000, .fpscr = 0x00040015, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 nans, flushed denormals and signed zeros",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0C54,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
        },
        .{ .qd = 0x7FC00000_00000000_7FC00000_7FC00000, .fpscr = 0x00040089, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 exact cancellation and zero signs",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0C54,
            .qd = 0x80000000_3F000000_C1000000_C0C00000,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .qm = 0x3E800000_BF800000_40800000_40400000,
        },
        .{ .qd = 0x80000000_00000000_C1000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 a single rounding near the top of the range",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0C54,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .qm = 0xBF800800_3F800800_3F800800_3F800800,
        },
        .{ .qd = 0x7F7FFFFF_3A000400_BF801000_33800000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f16 ordinary values, overflow and subnormals",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0C54,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0x7C00FC00_06907753_54F027EF_BD004580, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f16 infinities, nans and subnormals",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0C54,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
        },
        .{ .qd = 0x7E005000_00000000_7E007E00_7E007E00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vfms.f32 ordinary values and rounding",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0C54,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
        },
        .{ .qd = 0x42F20000_BCF5C28B_3F400000_C0600000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfms.f32 overflow, infinities and infinity times zero with a qnan addend",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0C54,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
        },
        .{ .qd = 0xFF800000_7FC00000_40000000_FF800000, .fpscr = 0x00040015, .vpr = 0x00000000 },
    ),
    vec(
        "vfms.f32 nans, flushed denormals and signed zeros",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0C54,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
        },
        .{ .qd = 0x7FC00000_80000000_7FC00000_7FC00000, .fpscr = 0x00040089, .vpr = 0x00000000 },
    ),
    vec(
        "vfms.f32 exact cancellation and zero signs",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0C54,
            .qd = 0x80000000_3F000000_C1000000_C0C00000,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .qm = 0x3E800000_BF800000_40800000_40400000,
        },
        .{ .qd = 0x00000000_3F800000_C1000000_C1400000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vfms.f32 a single rounding near the top of the range",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0C54,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .qm = 0xBF800800_3F800800_3F800800_3F800800,
        },
        .{ .qd = 0x7F7FFFFF_C0000800_BF801000_C0001000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfms.f16 ordinary values, overflow and subnormals",
        .{
            .hw1 = 0xEF32,
            .hw2 = 0x0C54,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0xFC00FC00_868CFC00_5790A76C_3A00C300, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vfms.f16 infinities, nans and subnormals",
        .{
            .hw1 = 0xEF32,
            .hw2 = 0x0C54,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
        },
        .{ .qd = 0x7E00FC00_00008010_7E007E00_7E00FC00, .fpscr = 0x00040015, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f16 with fz16 flushes subnormals",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0C54,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x7E005000_00000000_7E007E00_7E007E00, .fpscr = 0x000C0001, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0C54,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
            .fpscr = 0x03C40010,
        },
        .{ .qd = 0x42F20000_BCF5C28B_3F400000_C0600000, .fpscr = 0x03C40010, .vpr = 0x00000000 },
    ),
};
