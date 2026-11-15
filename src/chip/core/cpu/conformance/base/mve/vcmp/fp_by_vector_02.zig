//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fp_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmp.f32 ge q7 with itself",
        .{ .hw1 = 0xEE3F, .hw2 = 0x1F0E, .qn = 0x7F800000_00000001_40000000_7FC00001 },
        .{ .vpr = 0x0000FFFF, .fpscr = 0x00040000 },
    ),
    vec(
        "flags add to bits already set and fz clear still flushes",
        .{
            .hw1 = 0xEE33,
            .hw2 = 0x1F84,
            .qn = 0x7F800000_00000001_40000000_7FC00001,
            .qm = 0x7F800000_00000000_7F800001_3F800000,
            .fpscr = 0x00040010,
        },
        .{ .vpr = 0x000000FF, .fpscr = 0x00040091 },
    ),
};
