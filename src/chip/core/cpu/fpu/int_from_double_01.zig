//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("int_types.zig");

const Double = defs.Double;
const f = defs.f;

pub const values = [_]Double{
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "2^31 - 0.5 truncates",
        .input = .{ .a = 0x41DF_FFFF_FFE0_0000, .mode = .zero },
        .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTR",
        .name = "2^31 - 0.5 rounds out of range",
        .input = .{ .a = 0x41DF_FFFF_FFE0_0000 },
        .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-2^31 - 0.5 truncates",
        .input = .{ .a = 0xC1E0_0000_0010_0000, .mode = .zero },
        .expect = .{ .bits = 0x8000_0000, .flags = f.ixc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "1e300 saturates",
        .input = .{ .a = 0x7E37_E43C_8800_759C, .mode = .zero },
        .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "-1e300 saturates",
        .input = .{ .a = 0xFE37_E43C_8800_759C, .mode = .zero },
        .expect = .{ .bits = 0x8000_0000, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "2^32 - 1 is exact",
        .input = .{ .a = 0x41EF_FFFF_FFE0_0000, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0xFFFF_FFFF },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "2^32 saturates",
        .input = .{ .a = 0x41F0_0000_0000_0000, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ioc },
    },
    .{
        .encoding = "VCVT (between floating-point and integer)",
        .name = "smallest denormal",
        .input = .{ .a = 1, .unsigned = true, .mode = .zero },
        .expect = .{ .bits = 0, .flags = f.ixc },
    },
};
