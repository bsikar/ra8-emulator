//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("scalar_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vfma.f32 against a signalling nan",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .rm = 0x7F800001,
        },
        .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 against -0.0",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0x80000000_3F000000_C1000000_C0C00000,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .rm = 0x80000000,
        },
        .{ .qd = 0x00000000_3F000000_C1000000_C0C00000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 against infinity",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x7F800000,
        },
        .{ .qd = 0x7FC00000_7F800000_7F800000_7F800000, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 against a denormal, which reads as zero with idc",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .rm = 0x10,
        },
        .{ .qd = 0xFF800000_7FC00000_3F800000_3F800000, .fpscr = 0x00040080, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f32 against the largest finite value",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x0E42,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .rm = 0x7F7FFFFF,
        },
        .{ .qd = 0x7F800000_7F800000_BF801000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f16 against 3.0 with junk in the high half of rm",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E42,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0xDEAD4200,
        },
        .{ .qd = 0x4600FC00_27AFFB37_56D034D1_C6404580, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f16 against infinity",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .rm = 0x17C00,
        },
        .{ .qd = 0x7E007C00_7E007C00_7C007E00_7E007E00, .fpscr = 0x00040001, .vpr = 0x00000000 },
    ),
    vec(
        "vfma.f16 against a subnormal",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x0E42,
            .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0x12340001,
        },
        .{ .qd = 0x7E00FBFF_00000124_BC004000_7E00FC00, .fpscr = 0x00040019, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f32 against 3.0",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .rm = 0x40400000,
        },
        .{ .qd = 0x43978000_40400000_40600000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f32 against 1e10, with overflow and infinity times zero",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x501502F9,
        },
        .{ .qd = 0x7FC00000_7FC00000_7149F2CA_7149F2CA, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f32 against a signalling nan",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0x7F800001_80000020_80000000_00000000,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .rm = 0x7F800001,
        },
        .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f32 against -0.0",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0x80000000_3F000000_C1000000_C0C00000,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .rm = 0x80000000,
        },
        .{ .qd = 0x00000000_3E800000_80000000_C1400000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f32 against infinity",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .rm = 0x7F800000,
        },
        .{ .qd = 0x7F800000_7F800000_7F800000_7F800000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f32 against a denormal, which reads as zero with idc",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0xFF800000_7FC00000_3F800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .rm = 0x10,
        },
        .{ .qd = 0xFF800000_7FC00000_C0000000_3FC00000, .fpscr = 0x00040080, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f32 against the largest finite value",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1E42,
            .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .rm = 0x7F7FFFFF,
        },
        .{ .qd = 0x7F800000_7F7FFFFF_7F7FFFFF_7F7FFFFF, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
    vec(
        "vfmas.f16 against 3.0 with junk in the high half of rm",
        .{
            .hw1 = 0xFE33,
            .hw2 = 0x1E42,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .rm = 0xDEAD4200,
        },
        .{ .qd = 0x42007C00_4200FC00_5CBC4200_43004480, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};
