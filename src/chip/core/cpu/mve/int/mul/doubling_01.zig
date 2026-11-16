//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const a = defs.a;
const c = defs.c;
const d = defs.d;
const VDoubling = defs.VDoubling;

pub const values = [_]VDoubling{
    .{
        .encoding = "VQDMLAH T1",
        .name = "s8 saturates",
        .input = .{ .da = d, .n = a, .scalar = 0x80, .size = .byte, .form = .{} },
        .expect = .{ .value = 0x7F223344D667788999AB804CDEEFFFFF, .saturated = true },
    },
    .{
        .encoding = "VQDMLAH T1",
        .name = "s16",
        .input = .{ .da = d, .n = c, .scalar = 0x1234, .size = .half, .form = .{} },
        .expect = .{ .value = 0x112233445566778899A9BBCBF021ECCC, .saturated = false },
    },
    .{
        .encoding = "VQDMLAH T1",
        .name = "s32 saturates",
        .input = .{ .da = d, .n = a, .scalar = 0x80000000, .size = .word, .form = .{} },
        .expect = .{ .value = 0x7FFFFFFFD566778998AB3C4CDDEFFEFF, .saturated = true },
    },
    .{
        .encoding = "VQRDMLAH T1",
        .name = "s8",
        .input = .{ .da = d, .n = c, .scalar = 0x7F, .size = .byte, .form = .{ .round = true } },
        .expect = .{ .value = 0x112333465569778C98A8BAC95BED8000, .saturated = false },
    },
    .{
        .encoding = "VQRDMLAH T1",
        .name = "s16 most negative scalar",
        .input = .{ .da = a, .n = a, .scalar = 0x8000, .size = .half, .form = .{ .round = true } },
        .expect = .{ .value = 0x00000000000000000000000000000000, .saturated = false },
    },
    .{
        .encoding = "VQRDMLAH T1",
        .name = "s32",
        .input = .{ .da = d, .n = c, .scalar = 0x7FFFFFFF, .size = .word, .form = .{ .round = true } },
        .expect = .{ .value = 0x112333465569778C99A9BBC95DEE7EFF, .saturated = false },
    },
    .{
        .encoding = "VQDMLASH T1",
        .name = "s8",
        .input = .{ .da = d, .n = c, .scalar = 0x55, .size = .byte, .form = .{ .scalar_addend = true } },
        .expect = .{ .value = 0x55555556555755515556555632555655, .saturated = false },
    },
    .{
        .encoding = "VQDMLASH T1",
        .name = "s32 saturates",
        .input = .{ .da = a, .n = a, .scalar = 0x0, .size = .word, .form = .{ .scalar_addend = true } },
        .expect = .{ .value = 0x7FFFFFFF7FFFFFFE0001FDFE00000001, .saturated = true },
    },
    .{
        .encoding = "VQRDMLASH T1",
        .name = "s16",
        .input = .{
            .da = d,
            .n = a,
            .scalar = 0xFFFF8001,
            .size = .half,
            .form = .{ .scalar_addend = true, .round = true },
        },
        .expect = .{ .value = 0x80008001D56680008000800080018001, .saturated = true },
    },
    .{
        .encoding = "VQRDMLASH T1",
        .name = "s8 saturates",
        .input = .{
            .da = a,
            .n = a,
            .scalar = 0x7F,
            .size = .byte,
            .form = .{ .scalar_addend = true, .round = true },
        },
        .expect = .{ .value = 0x7F7F7F7F7F7F7F7F7F7F7F7F7F7F7F7F, .saturated = true },
    },
};
