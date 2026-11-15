//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vld_il_types.zig");

const none = defs.none;
const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "d set would name q8 and is unclaimed",
        .{
            .hw1 = 0xFCD1,
            .hw2 = 0x3E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "vld2 from q7 runs past q7 and is unclaimed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0xFE00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0, 0, 0 },
        },
        none,
    ),
    vec(
        "vld4 from q5 runs past q7 and is unclaimed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0xBE01,
            .base = 0x20000200,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0,
            },
        },
        none,
    ),
    vec(
        "size 11 is unclaimed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3F80,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "pattern 2 of vld2 is unclaimed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E40,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "a pc base is unclaimed",
        .{
            .hw1 = 0xFC9F,
            .hw2 = 0x3E00,
            .base = 0x00000000,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "an sp base with writeback is unclaimed",
        .{
            .hw1 = 0xFCBD,
            .hw2 = 0x3E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "hw2 bits 4 to 1 set are unclaimed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E02,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "hw2 bit 12 clear is unclaimed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x2E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "hw1 bit 7 clear is unclaimed",
        .{
            .hw1 = 0xFC11,
            .hw2 = 0x3E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        none,
    ),
    vec(
        "the 16-bit space is unclaimed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
            .size = 2,
        },
        none,
    ),
};
