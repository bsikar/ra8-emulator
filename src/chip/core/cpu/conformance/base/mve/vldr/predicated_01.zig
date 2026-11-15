//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps word lanes 2 and 3 and zeroes the rest",
        .{
            .hw1 = 0xED91,
            .hw2 = 0x5F00,
            .base = 0x20000200,
            .qd = 0x11112222_33334444_55556666_77778888,
            .vpr = 0x0088FF00,
        },
        .{
            .qd = 0xFADDC0A3_86694C2F_00000000_00000000,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000FF00,
        },
    ),
    vec(
        "every other byte predicated on vldrb zeroes the rest",
        .{
            .hw1 = 0xED91,
            .hw2 = 0x5E00,
            .base = 0x20000210,
            .qd = 0x11112222_33334444_55556666_77778888,
            .vpr = 0x00885555,
        },
        .{
            .qd = 0x00AD0073_003900FF_00C5008B_00510017,
            .rn = 0x20000210,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00005555,
        },
    ),
    vec(
        "a word predicated past its first byte is not loaded",
        .{
            .hw1 = 0xED91,
            .hw2 = 0x5F00,
            .base = 0x20000200,
            .qd = 0x11112222_33334444_55556666_77778888,
            .vpr = 0x0088FEFE,
        },
        .{
            .qd = 0xFADDC0A3_00000000_12F5D8BB_00000000,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000FEFE,
        },
    ),
    vec(
        "every lane predicated off reaches no memory, so a misaligned base cannot fault",
        .{
            .hw1 = 0xEDB1,
            .hw2 = 0x5F00,
            .base = 0x20000202,
            .qd = 0x11112222_33334444_55556666_77778888,
            .vpr = 0x00880000,
        },
        .{
            .qd = 0x00000000_00000000_00000000_00000000,
            .rn = 0x20000202,
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
        "vstrh with half lanes 0, 2, 4 and 6 predicated",
        .{
            .hw1 = 0xED81,
            .hw2 = 0x5E80,
            .base = 0x20000220,
            .qd = 0x11112222_33334444_55556666_77778888,
            .vpr = 0x00883333,
        },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000220,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D2222_26094444_B2956666_3E218888,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00003333,
        },
    ),
    vec(
        "vstrw with lanes 0 and 3 predicated, writeback still happens",
        .{
            .hw1 = 0xECA1,
            .hw2 = 0x5F04,
            .base = 0x20000210,
            .qd = 0x11112222_33334444_55556666_77778888,
            .vpr = 0x0088F00F,
        },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000220,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0x11112222_56391CFF_E2C5A88B_77778888,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000F00F,
        },
    ),
    vec(
        "the loop tail on halfword loads stops after lane 2",
        .{
            .hw1 = 0xED91,
            .hw2 = 0x5E80,
            .base = 0x20000210,
            .qd = 0x11112222_33334444_55556666_77778888,
            .lr = 3,
            .fpscr = 0x00010000,
        },
        .{
            .qd = 0x00000000_00000000_0000A88B_6E513417,
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
        "the loop tail on byte stores stops after lane 4",
        .{
            .hw1 = 0xED81,
            .hw2 = 0x5E00,
            .base = 0x20000230,
            .qd = 0x11112222_33334444_55556666_77778888,
            .lr = 5,
            .fpscr = 0x00000000,
        },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000230,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_82654866_77778888,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "eci a0a1 keeps the done beats of qd on a load",
        .{
            .hw1 = 0xECB1,
            .hw2 = 0x5F04,
            .base = 0x20000220,
            .qd = 0x11112222_33334444_55556666_77778888,
            .it = 0x20,
        },
        .{
            .qd = 0x9A7D6043_2609ECCF_55556666_77778888,
            .rn = 0x20000230,
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
        "eci a0a1a2 stores only beat 3",
        .{
            .hw1 = 0xED81,
            .hw2 = 0x5E80,
            .base = 0x20000200,
            .qd = 0x11112222_33334444_55556666_77778888,
            .it = 0x40,
        },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000200,
            .mem = .{
                0x11112222_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};
