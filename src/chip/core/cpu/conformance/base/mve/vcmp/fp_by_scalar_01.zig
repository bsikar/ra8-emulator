//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fp_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmp.f32 eq against r2 = 1.0",
        .{ .hw1 = 0xEE33, .hw2 = 0x0F42, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 },
        .{ .vpr = 0x000000F0, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f16 eq against the low half of r2, with an snan lane",
        .{ .hw1 = 0xFE33, .hw2 = 0x0F42, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 },
        .{ .vpr = 0x0000000C, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 ne against r2 = 1.0",
        .{ .hw1 = 0xEE33, .hw2 = 0x0FC2, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 },
        .{ .vpr = 0x0000FF0F, .fpscr = 0x00040000 },
    ),
    vec(
        "vcmp.f16 ne against the low half of r2, with an snan lane",
        .{ .hw1 = 0xFE33, .hw2 = 0x0FC2, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 },
        .{ .vpr = 0x0000FFF3, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 ge against r2 = 1.0",
        .{ .hw1 = 0xEE33, .hw2 = 0x1F42, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 },
        .{ .vpr = 0x00000FF0, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f16 ge against the low half of r2, with an snan lane",
        .{ .hw1 = 0xFE33, .hw2 = 0x1F42, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 },
        .{ .vpr = 0x0000003C, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 lt against r2 = 1.0",
        .{ .hw1 = 0xEE33, .hw2 = 0x1FC2, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 },
        .{ .vpr = 0x0000F00F, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f16 lt against the low half of r2, with an snan lane",
        .{ .hw1 = 0xFE33, .hw2 = 0x1FC2, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 },
        .{ .vpr = 0x0000FFC3, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 gt against r2 = 1.0",
        .{ .hw1 = 0xEE33, .hw2 = 0x1F62, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 },
        .{ .vpr = 0x00000F00, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f16 gt against the low half of r2, with an snan lane",
        .{ .hw1 = 0xFE33, .hw2 = 0x1F62, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 },
        .{ .vpr = 0x00000030, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 le against r2 = 1.0",
        .{ .hw1 = 0xEE33, .hw2 = 0x1FE2, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 },
        .{ .vpr = 0x0000F0FF, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f16 le against the low half of r2, with an snan lane",
        .{ .hw1 = 0xFE33, .hw2 = 0x1FE2, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 },
        .{ .vpr = 0x0000FFCF, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 eq against a signalling nan in r12 raises ioc",
        .{ .hw1 = 0xEE33, .hw2 = 0x0F4C, .qn = 0x80000000_00000000_C0000000_3F800000, .rm = 0x7F800001 },
        .{ .vpr = 0x00000000, .fpscr = 0x00040001 },
    ),
    vec(
        "vcmp.f32 gt against a quiet nan in lr raises ioc",
        .{ .hw1 = 0xEE33, .hw2 = 0x1F6E, .qn = 0x80000000_00000000_C0000000_3F800000, .rm = 0x7FC00001 },
        .{ .vpr = 0x00000000, .fpscr = 0x00040001 },
    ),
};
