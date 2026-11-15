//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const FromFixed64 = defs.FromFixed64;

pub const values = [_]FromFixed64{
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-2 at 1 bit is -1",
        .input = .{ .a = 0xFFFF_FFFE, .fbits = 1 },
        .expect = .{ .bits = 0xBFF0_0000_0000_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "2^31-1 at 31 bits is exact",
        .input = .{ .a = 0x7FFF_FFFF, .fbits = 31 },
        .expect = .{ .bits = 0x3FEF_FFFF_FFC0_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "2^32-1 at 32 bits is exact",
        .input = .{ .a = 0xFFFF_FFFF, .fbits = 32, .unsigned = true },
        .expect = .{ .bits = 0x3FEF_FFFF_FFE0_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "-32767 at 1 bit",
        .input = .{ .a = 0x0000_8001, .width = 16, .fbits = 1 },
        .expect = .{ .bits = 0xC0CF_FFC0_0000_0000 },
    },
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "65535 at 16 bits",
        .input = .{ .a = 0x0000_FFFF, .width = 16, .fbits = 16, .unsigned = true },
        .expect = .{ .bits = 0x3FEF_FFE0_0000_0000 },
    },
};
