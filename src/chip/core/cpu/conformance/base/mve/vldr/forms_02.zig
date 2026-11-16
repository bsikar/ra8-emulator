//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vstrh.16 pre offset add",
        .{ .hw1 = 0xED81, .hw2 = 0x5E81, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000200,
            .mem = .{
                0x22223333_44445555_66667777_88886447,
                0xCAAD9073_56391CFF_E2C5A88B_6E511111,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 pre index subtract with writeback",
        .{ .hw1 = 0xED21, .hw2 = 0x5F02, .base = 0x20000238, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000230,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x11112222_33334444_55556666_77778888,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 post index add with writeback",
        .{ .hw1 = 0xECA5, .hw2 = 0x5F7F, .base = 0x20000210, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x2000040C,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0x11112222_33334444_55556666_77778888,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 at a byte address faults unaligned and writes nothing",
        .{ .hw1 = 0xED81, .hw2 = 0x5F00, .base = 0x20000203, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .fault = .unaligned,
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000203,
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
        "vstrb.8 from q7 through sp",
        .{ .hw1 = 0xED8D, .hw2 = 0xFE08, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000200,
            .mem = .{
                0x55556666_77778888_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_11112222_33334444,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};
