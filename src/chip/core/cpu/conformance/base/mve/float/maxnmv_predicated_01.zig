//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("maxnmv_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt p0 0x0f0f folds lanes 0 and 1",
        .{
            .hw1 = 0xEEEE,
            .hw2 = 0x2F02,
            .qm = 0x7FC00001_7F800000_3F800000_7F800001,
            .rda = 0x0,
            .vpr = 0x008800FF,
        },
        .{ .rda = 0x3F800000, .fpscr = 0x00040001, .vpr = 0x000000FF },
    ),
    vec(
        "vpt p0 0xfff0 skips lane 0 and its snan",
        .{
            .hw1 = 0xEEEE,
            .hw2 = 0x2F82,
            .qm = 0x7FC00001_7F800000_3F800000_7F800001,
            .rda = 0x0,
            .vpr = 0x0088FFF0,
        },
        .{ .rda = 0x0, .fpscr = 0x00040000, .vpr = 0x0000FFF0 },
    ),
    vec(
        "a lane folds only when its first byte is predicated",
        .{
            .hw1 = 0xEEEE,
            .hw2 = 0x2F02,
            .qm = 0x7FC00001_7F800000_3F800000_7F800001,
            .rda = 0x0,
            .vpr = 0x0088FFFE,
        },
        .{ .rda = 0x7F800000, .fpscr = 0x00040000, .vpr = 0x0000FFFE },
    ),
    vec(
        "the loop tail stops at lane 2",
        .{
            .hw1 = 0xEEEE,
            .hw2 = 0x2F02,
            .qm = 0xBF000000_40200000_C0400000_3F800000,
            .rda = 0x0,
            .lr = 2,
            .fpscr = 0x00020000,
        },
        .{ .rda = 0x3F800000, .fpscr = 0x00020000 },
    ),
    vec(
        "the f16 loop tail at ltpsize 1",
        .{
            .hw1 = 0xFEEE,
            .hw2 = 0x2F82,
            .qm = 0xC0007E00_00008001_FC003C00_7C017E01,
            .rda = 0x0,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{ .rda = 0x0, .fpscr = 0x00010001 },
    ),
    vec(
        "no predicated lanes leave rda as is",
        .{
            .hw1 = 0xEEEE,
            .hw2 = 0x2F02,
            .qm = 0x7FC00001_7F800000_3F800000_7F800001,
            .rda = 0x12345678,
            .vpr = 0x00880000,
        },
        .{ .rda = 0x12345678, .fpscr = 0x00040000 },
    ),
};
