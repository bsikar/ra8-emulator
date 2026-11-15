//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("rint_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vrintn.f32 halves and a negative fraction",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x0444,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBE99999A_C0200000_3FC00000_3F000000,
        },
        .{ .qd = 0x80000000_C0000000_40000000_00000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintn.f32 fractions near the integer limit and -0",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x0444,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD,
        },
        .{ .qd = 0x80000000_4B000000_C0400000_40400000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintn.f16 halves, fractions and 1023.5",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x0444,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
        },
        .{ .qd = 0x80006400_C2004200_8000C000_40000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintx.f32 halves and a negative fraction",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBE99999A_C0200000_3FC00000_3F000000,
        },
        .{ .qd = 0x80000000_C0000000_40000000_00000000, .fpscr = 0x00040010 },
    ),
    vec(
        "vrintx.f32 fractions near the integer limit and -0",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD,
        },
        .{ .qd = 0x80000000_4B000000_C0400000_40400000, .fpscr = 0x00040010 },
    ),
    vec(
        "vrintx.f16 halves, fractions and 1023.5",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
        },
        .{ .qd = 0x80006400_C2004200_8000C000_40000000, .fpscr = 0x00040010 },
    ),
    vec(
        "vrinta.f32 halves and a negative fraction",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x0544,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBE99999A_C0200000_3FC00000_3F000000,
        },
        .{ .qd = 0x80000000_C0400000_40000000_3F800000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrinta.f32 fractions near the integer limit and -0",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x0544,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD,
        },
        .{ .qd = 0x80000000_4B000000_C0400000_40400000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrinta.f16 halves, fractions and 1023.5",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x0544,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
        },
        .{ .qd = 0x80006400_C2004200_8000C200_40003C00, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintz.f32 halves and a negative fraction",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x05C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBE99999A_C0200000_3FC00000_3F000000,
        },
        .{ .qd = 0x80000000_C0000000_3F800000_00000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintz.f32 fractions near the integer limit and -0",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x05C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD,
        },
        .{ .qd = 0x80000000_4AFFFFFE_C0000000_40000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintz.f16 halves, fractions and 1023.5",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x05C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
        },
        .{ .qd = 0x800063FE_C0004000_8000C000_3C000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintm.f32 halves and a negative fraction",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x06C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBE99999A_C0200000_3FC00000_3F000000,
        },
        .{ .qd = 0xBF800000_C0400000_3F800000_00000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintm.f32 fractions near the integer limit and -0",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x06C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD,
        },
        .{ .qd = 0x80000000_4AFFFFFE_C0400000_40000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintm.f16 halves, fractions and 1023.5",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x06C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
        },
        .{ .qd = 0x800063FE_C2004000_BC00C200_3C000000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintp.f32 halves and a negative fraction",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x07C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBE99999A_C0200000_3FC00000_3F000000,
        },
        .{ .qd = 0x80000000_C0000000_40000000_3F800000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintp.f32 fractions near the integer limit and -0",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x07C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD,
        },
        .{ .qd = 0x80000000_4B000000_C0000000_40400000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintp.f16 halves, fractions and 1023.5",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x07C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x800063FF_C1664166_B4CDC100_3E003800,
        },
        .{ .qd = 0x80006400_C0004200_8000C000_40003C00, .fpscr = 0x00040000 },
    ),
};
