//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("wide_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vldrb.s16 pre offset add sign-extends",
        .{ .hw1 = 0xED91, .hw2 = 0x4E83, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x0069004C_002F0012_FFF5FFD8_FFBBFF9E,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrb.u16 post index with writeback zero-extends",
        .{ .hw1 = 0xFCB1, .hw2 = 0x4EFF, .base = 0x20000210, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x00E200C5_00A8008B_006E0051_00340017,
            .rn = 0x2000028F,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrb.s32 pre index subtract with writeback",
        .{ .hw1 = 0xED32, .hw2 = 0x4F04, .base = 0x20000228, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0xFFFFFFB2_FFFFFF95_00000078_0000005B,
            .rn = 0x20000224,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrb.u32 at an odd address needs no alignment",
        .{ .hw1 = 0xFD93, .hw2 = 0x4F00, .base = 0x20000233, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x00000065_00000048_0000002B_0000000E,
            .rn = 0x20000233,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrh.s32 pre offset add sign-extends",
        .{ .hw1 = 0xED9C, .hw2 = 0x4F02, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0xFFFF8669_00004C2F_000012F5_FFFFD8BB,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrh.u32 post index subtract with writeback",
        .{ .hw1 = 0xFC3D, .hw2 = 0x4F10, .base = 0x20000230, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x00008265_0000482B_00000EF1_0000D4B7,
            .rn = 0x20000210,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrh.s32 into q7 from r7",
        .{ .hw1 = 0xED9F, .hw2 = 0xEF00, .base = 0x20000218, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0xFFFFCAAD_FFFF9073_00005639_00001CFF,
            .rn = 0x20000218,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrh.s32 at an odd address faults unaligned and changes nothing",
        .{ .hw1 = 0xEDB9, .hw2 = 0x4F00, .base = 0x20000201, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .fault = .unaligned,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000201,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vldrb.s16 with a subtract that wraps faults unmapped",
        .{ .hw1 = 0xED31, .hw2 = 0x4E88, .base = 0x00000004, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .fault = .unmapped,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x00000004,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrb.16 pre offset add keeps the low byte of each half",
        .{ .hw1 = 0xED81, .hw2 = 0x4E81, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C99_BBDDFF22_44668847,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrb.32 pre index subtract with writeback",
        .{ .hw1 = 0xED22, .hw2 = 0x4F08, .base = 0x20000230, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000228,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_BBFF4488_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrh.32 post index add with writeback keeps the low half of each word",
        .{ .hw1 = 0xECAE, .hw2 = 0x4F7F, .base = 0x20000220, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x2000031E,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_AABBEEFF_33447788,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};
