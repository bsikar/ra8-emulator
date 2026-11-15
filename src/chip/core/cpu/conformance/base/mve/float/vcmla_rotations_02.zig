//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vcmla_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmla.f16 #180 ordinary values, overflow and subnormals",
        .{
            .hw1 = 0xFD22,
            .hw2 = 0x0844,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0x7C00FC00_C200FC00_564BA76C_BC00C300, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f16 #180 infinities, nans and subnormals",
        .{
            .hw1 = 0xFD22,
            .hw2 = 0x0844,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
        },
        .{ .qd = 0x7E00FC00_80408010_7E007E00_7E00FC00, .fpscr = 0x00040015, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f32 #270 ordinary values and rounding",
        .{
            .hw1 = 0xFDB2,
            .hw2 = 0x0844,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
        },
        .{ .qd = 0x42C63333_C1A80000_40B80000_00000000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f32 #270 overflow, infinities and infinity times zero with a qnan addend",
        .{
            .hw1 = 0xFDB2,
            .hw2 = 0x0844,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
        },
        .{ .qd = 0xFF800000_7FC00000_FF800000_B29C7F00, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f32 #270 nans, flushed denormals and signed zeros",
        .{
            .hw1 = 0xFDB2,
            .hw2 = 0x0844,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
        },
        .{ .qd = 0x7FC00000_7FC00000_80000000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f32 #270 exact cancellation and zero signs",
        .{
            .hw1 = 0xFDB2,
            .hw2 = 0x0844,
            .qd = 0x80000000_3F000000_C1000000_C0C00000,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .qm = 0x3E800000_BF800000_40800000_40400000,
        },
        .{ .qd = 0x80000000_3F000000_C1000000_C0C00000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f16 #270 ordinary values, overflow and subnormals",
        .{
            .hw1 = 0xFDA2,
            .hw2 = 0x0844,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0x80027E00_C200FB53_5632CD40_45C00000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f16 #270 infinities, nans and subnormals",
        .{
            .hw1 = 0xFDA2,
            .hw2 = 0x0844,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
        },
        .{ .qd = 0x7E00FBFF_00008008_C0007E00_7E00FC00, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f32 #0 rounds once, where a separate multiply would lose the low bit",
        .{
            .hw1 = 0xFC32,
            .hw2 = 0x0844,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .qm = 0xBF800800_3F800800_3F800800_3F800800,
        },
        .{ .qd = 0x7F7FFFFF_3A000400_33800000_33800000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f32 #180 fused near the top of the range",
        .{
            .hw1 = 0xFD32,
            .hw2 = 0x0844,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .qm = 0xBF800800_3F800800_3F800800_3F800800,
        },
        .{ .qd = 0x7F7FFFFF_C0000800_C0001000_C0001000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vcmla.f16 #0 with fz16 flushes subnormals",
        .{
            .hw1 = 0xFC22,
            .hw2 = 0x0844,
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
            .hw1 = 0xFCB2,
            .hw2 = 0x0844,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
            .fpscr = 0x03C40010,
        },
        .{ .qd = 0x42C9CCCD_41A80000_C0C80000_40000000, .fpscr = 0x03C40010, .vpr = 0x00000000 },
    ),
    vec(
        "qn equal to qm squares the pair into the accumulator",
        .{
            .hw1 = 0xFC38,
            .hw2 = 0x0848,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
        },
        .{ .qd = 0x42C80000_322BCC77_BE800000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6 and q5 at f16",
        .{
            .hw1 = 0xFDAC,
            .hw2 = 0xE84A,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0x80027E00_C200FB53_5632CD40_45C00000, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
};
