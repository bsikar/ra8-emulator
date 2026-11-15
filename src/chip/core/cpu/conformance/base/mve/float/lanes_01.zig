//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vadd.f32 ordinary values and rounding",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
        },
        .{ .qd = 0xC0800000_3ECCCCCD_BFC00000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vadd.f32 overflow, underflow and infinity times zero",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
        },
        .{ .qd = 0x3F800000_7F800000_7149F2CA_7149F2CA, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vadd.f32 nans, a flushed denormal and signed zeros",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
        },
        .{ .qd = 0x7F800000_1EBCE508_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vadd.f32 exact cancellation and zero signs",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .qm = 0x3E800000_BF800000_40800000_40400000,
        },
        .{ .qd = 0x3E800000_BF000000_40800000_40A00000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vadd.f32 near the top of the range",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .qm = 0xBF800800_3F800800_3F800800_3F800800,
        },
        .{ .qd = 0xB9800000_40000800_3F800800_40000800, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vadd.f32 equal and nearly equal lanes, with a flushed tiny difference",
        .{
            .hw1 = 0xEF02,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0xC0600000_00800000_BF800000_3F800000,
            .qm = 0xC0600000_00800001_3F800000_3F800000,
        },
        .{ .qd = 0xC0E00000_01000000_00000000_40000000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vadd.f16 ordinary values, overflow and subnormals",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0x7C00B800_251F60B0_C4003666_BE004480, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vadd.f16 infinities, nans and subnormals",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
        },
        .{ .qd = 0x18196440_44003800_7E007E00_BC007C00, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f32 ordinary values and rounding",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
        },
        .{ .qd = 0x41200000_BE4CCCCE_C0200000_BFC00000, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f32 overflow, underflow and infinity times zero",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
            .qm = 0x3F800000_00000000_8DA24260_501502F9,
        },
        .{ .qd = 0xBF800000_7F800000_7149F2CA_7149F2CA, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f32 nans, a flushed denormal and signed zeros",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_1E3CE508_00000010_7FC00001,
            .qm = 0x7F800000_1E3CE508_7F800001_40000000,
        },
        .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f32 exact cancellation and zero signs",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x80000000_3F000000_00000000_40000000,
            .qm = 0x3E800000_BF800000_40800000_40400000,
        },
        .{ .qd = 0xBE800000_3FC00000_C0800000_BF800000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f32 near the top of the range",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x3F800000_3F800800_00000000_3F800800,
            .qm = 0xBF800800_3F800800_3F800800_3F800800,
        },
        .{ .qd = 0x40000400_00000000_BF800800_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f32 equal and nearly equal lanes, with a flushed tiny difference",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0xC0600000_00800000_BF800000_3F800000,
            .qm = 0xC0600000_00800001_3F800000_3F800000,
        },
        .{ .qd = 0x00000000_80000000_C0000000_00000000, .fpscr = 0x00040008, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f16 ordinary values, overflow and subnormals",
        .{
            .hw1 = 0xEF32,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0xFC00B800_00000000_4900B267_C100BE00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
    vec(
        "vsub.f16 infinities, nans and subnormals",
        .{
            .hw1 = 0xEF32,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
        },
        .{ .qd = 0x00006380_C400B800_7E007E00_3C007C00, .fpscr = 0x00040011, .vpr = 0x00000000 },
    ),
};
