//! Conformance vectors for VSELEQ, VSELVS, VSELGE and VSELGT, worked from
//! the VSEL pseudocode in the Arm ARM (DDI0553): each condition both held
//! and failed (including flags that must not matter), and NaNs, signalling
//! ones included, moved as raw bits with no flags raised.
const vector = @import("../conformance/vector.zig");
const case = @import("case.zig");

pub const V32 = vector.Vector(case.Select(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Select(u64), case.Result(u64));

pub const select32 = [_]V32{
    .{ .encoding = "VSELEQ.F32 T1", .name = "Z set takes Sn", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSELEQ.F32 T1", .name = "Z clear takes Sm", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSELEQ.F32 T1", .name = "only Z matters", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1011 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSELVS.F32 T1", .name = "V set takes Sn", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0001 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSELVS.F32 T1", .name = "V clear takes Sm", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1110 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSELGE.F32 T1", .name = "N=V=0 takes Sn", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSELGE.F32 T1", .name = "N=V=1 takes Sn", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1001 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSELGE.F32 T1", .name = "N set, V clear takes Sm", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSELGE.F32 T1", .name = "N clear, V set takes Sm", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0001 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSELGT.F32 T1", .name = "N=V, Z clear takes Sn", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSELGT.F32 T1", .name = "Z set takes Sm", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSELGT.F32 T1", .name = "N=V=1, Z clear takes Sn", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1001 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSELGT.F32 T1", .name = "N!=V takes Sm", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSELEQ.F32 T1", .name = "an sNaN moves untouched, no IOC", .input = .{ .a = 0x7F80_0001, .b = 0x4000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x7F80_0001 } },
};

pub const select64 = [_]V64{
    .{ .encoding = "VSELEQ.F64 T1", .name = "Z set takes Dn", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSELEQ.F64 T1", .name = "Z clear takes Dm", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VSELVS.F64 T1", .name = "V set takes Dn", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0001 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSELVS.F64 T1", .name = "V clear takes Dm", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b1110 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VSELGE.F64 T1", .name = "N=V=0 takes Dn", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSELGE.F64 T1", .name = "N=V=1 takes Dn", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b1001 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSELGT.F64 T1", .name = "N=V, Z clear takes Dn", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSELGT.F64 T1", .name = "Z set takes Dm", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VSELVS.F64 T1", .name = "an sNaN moves untouched, no IOC", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x7FF0_0000_0000_0001, .nzcv = 0b0000 }, .expect = .{ .bits = 0x7FF0_0000_0000_0001 } },
};

pub const claimed = [_][]const u8{
    "VSELEQ.F32 T1",
    "VSELVS.F32 T1",
    "VSELGE.F32 T1",
    "VSELGT.F32 T1",
    "VSELEQ.F64 T1",
    "VSELVS.F64 T1",
    "VSELGE.F64 T1",
    "VSELGT.F64 T1",
};

pub const covered = vector.encodingsOf(case.Select(u32), case.Result(u32), &select32) ++
    vector.encodingsOf(case.Select(u64), case.Result(u64), &select64);
