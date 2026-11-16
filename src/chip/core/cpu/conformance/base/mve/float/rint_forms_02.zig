//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("rint_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vrintn.f32 nans, a flushed denormal and -inf",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x0444,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xFF800000_00000001_7FC00001_7F800001,
        },
        .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081 },
    ),
    vec(
        "vrintn.f16 nans and kept denormals",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x0444,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xB8005640_3C007C00_80010001_7E017C01,
        },
        .{ .qd = 0x80005640_3C007C00_80000000_7E007E00, .fpscr = 0x00040001 },
    ),
    vec(
        "vrintx.f32 nans, a flushed denormal and -inf",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xFF800000_00000001_7FC00001_7F800001,
        },
        .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081 },
    ),
    vec(
        "vrintx.f16 nans and kept denormals",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xB8005640_3C007C00_80010001_7E017C01,
        },
        .{ .qd = 0x80005640_3C007C00_80000000_7E007E00, .fpscr = 0x00040011 },
    ),
    vec(
        "vrintp.f32 nans, a flushed denormal and -inf",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x07C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xFF800000_00000001_7FC00001_7F800001,
        },
        .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081 },
    ),
    vec(
        "vrintp.f16 nans and kept denormals",
        .{
            .hw1 = 0xFFB6,
            .hw2 = 0x07C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xB8005640_3C007C00_80010001_7E017C01,
        },
        .{ .qd = 0x80005640_3C007C00_80003C00_7E007E00, .fpscr = 0x00040001 },
    ),
    vec(
        "vrintm.f32 a negative flushed denormal, integers and -0.4999",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x06C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xBEFFFFFF_4B000001_3F800000_80400000,
        },
        .{ .qd = 0xBF800000_4B000001_3F800000_80000000, .fpscr = 0x00040080 },
    ),
    vec(
        "vrintx.f32 integers stay exact without ixc",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0x80000000_49800000_C0E00000_3F800000,
        },
        .{ .qd = 0x80000000_49800000_C0E00000_3F800000, .fpscr = 0x00040000 },
    ),
    vec(
        "vrintz.f32 qd = qm",
        .{ .hw1 = 0xFFBA, .hw2 = 0x85C8, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 },
        .{ .qd = 0x80000000_C0000000_3F800000_00000000, .fpscr = 0x00040000 },
    ),
    vec(
        "fpscr rmode and fz clear do not change vrintx",
        .{ .hw1 = 0xFFBA, .hw2 = 0xE4C2, .qm = 0xBE99999A_C0200000_3FC00000_3F000000, .fpscr = 0x00C40000 },
        .{ .qd = 0x80000000_C0000000_40000000_00000000, .fpscr = 0x00C40010 },
    ),
    vec(
        "flags add to the cumulative bits already set",
        .{
            .hw1 = 0xFFBA,
            .hw2 = 0x04C4,
            .qd = 0x11111111_22222222_33333333_44444444,
            .qm = 0xFF800000_00000001_7FC00001_7F800001,
            .fpscr = 0x00040002,
        },
        .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040083 },
    ),
};
