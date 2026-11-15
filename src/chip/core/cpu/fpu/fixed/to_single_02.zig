//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const f = defs.f;
const ToFixed32 = defs.ToFixed32;

pub const values = [_]ToFixed32{
    .{
        .encoding = "VCVT (between floating-point and fixed-point)",
        .name = "FZ flushes a denormal",
        .input = .{ .a = 0x0000_0001, .width = 16, .fbits = 16, .unsigned = true, .fz = 1 },
        .expect = .{ .bits = 0x0000_0000, .flags = f.idc },
    },
};
