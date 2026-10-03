//! Covers src/core/cpu/ops/eci_use.zig and the ECI kind the decode table
//! hands each group's encodings (RA8EMU-453).
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.core.cpu.decode;
const Instr = ra8.core.cpu.instr.Instr;
const Eci = ra8.core.cpu.op.Eci;

fn narrow(hw1: u16) Instr {
    return .{ .address = 0x100, .hw1 = hw1, .hw2 = 0, .size = 2 };
}

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0x100, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn kind(instr: Instr) !Eci {
    const hit = decode.decode(instr) orelse return error.NotClaimed;
    return hit.eci;
}

test "plain instructions refuse ECI" {
    try std.testing.expectEqual(Eci.refuses, try kind(narrow(0xBF00))); // nop
    try std.testing.expectEqual(Eci.refuses, try kind(narrow(0x1888))); // adds r0, r1, r2
}

test "load and store multiples restart" {
    try std.testing.expectEqual(Eci.restarts, try kind(narrow(0xC802))); // ldmia r0!, {r1}
    try std.testing.expectEqual(Eci.restarts, try kind(narrow(0xB403))); // push {r0, r1}
    try std.testing.expectEqual(Eci.restarts, try kind(wide(0xE8BD, 0x0003))); // pop.w {r0, r1}
}

test "BKPT, LE and LETP keep ECI; DLS, DLSTP and LCTP refuse it" {
    try std.testing.expectEqual(Eci.keeps, try kind(narrow(0xBE00)));
    try std.testing.expectEqual(Eci.keeps, try kind(wide(0xF00F, 0xC007))); // le
    try std.testing.expectEqual(Eci.keeps, try kind(wide(0xF01F, 0xC80F))); // letp
    try std.testing.expectEqual(Eci.refuses, try kind(wide(0xF042, 0xE001))); // dls lr, r2
    try std.testing.expectEqual(Eci.refuses, try kind(wide(0xF022, 0xE001))); // dlstp.32 lr, r2
    try std.testing.expectEqual(Eci.refuses, try kind(wide(0xF00F, 0xE001))); // lctp
}

test "beat-wise MVE groups honour ECI" {
    try std.testing.expectEqual(Eci.beat_wise, try kind(wide(0xEF22, 0x0844))); // vadd.i32
}
