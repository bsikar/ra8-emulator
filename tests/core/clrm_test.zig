//! Covers src/core/clrm.zig and src/core/clrm_hook.zig.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const clrm = ra8.core.csel.clrm;
const clrm_hook = ra8.core.csel.clrm_hook;

const base: u32 = 0x2200_0000;

/// movs r1, #5 / cmp r1, r1 / clrm {r1, r2, r3, ip, APSR} / bkpt.
/// The clrm is the one tz_nsc_cgc_usb's CMSE entry stub runs, assembled by
/// arm-none-eabi-as 13.3.rel1 for armv8.1-m.main.
const clear_stub = [_]u8{
    0x05, 0x21, //             2105       movs r1, #5
    0x89, 0x42, //             4289       cmp r1, r1
    0x9F, 0xE8, 0x0E, 0x90, // e89f 900e  clrm {r1, r2, r3, ip, APSR}
    0x00, 0xBE, //             be00       bkpt
};

test "decode reads the stub's list and refuses what is not CLRM" {
    const found = clrm.decode(0xE89F, 0x900E).?;
    try std.testing.expect(found.apsr);
    try std.testing.expect(found.clears(1) and found.clears(2) and found.clears(3) and found.clears(12));
    try std.testing.expect(!found.clears(0) and !found.clears(14));
    try std.testing.expect(clrm.decode(0xE89F, 0x4000).?.clears(14));
    try std.testing.expectEqual(@as(?clrm.Instruction, null), clrm.decode(0xE89E, 0x900E));
    try std.testing.expectEqual(@as(?clrm.Instruction, null), clrm.decode(0xE89F, 0x2001));
    try std.testing.expectEqual(@as(?clrm.Instruction, null), clrm.decode(0xE89F, 0x0000));
}

test "clearedApsr drops the flags and keeps the rest of xPSR" {
    try std.testing.expectEqual(@as(u32, 0x0100_0010), clrm.clearedApsr(0xF90F_0010));
}

test "a CLRM the CPU model cannot decode clears the listed registers and flags" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &clear_stub);

    var clears = clrm.Clears{};
    try clrm_hook.attach(core.handle, &clears);
    try core.setRegister(.r0, 0x1111);
    try core.setRegister(.r2, 0x2222);
    try core.setRegister(.r3, 0x3333);
    try core.setRegister(.r12, 0xCCCC);
    try core.setRegister(.lr, 0x4444);

    const fault = try core.run(base, 16, .{});
    try std.testing.expect(fault != null);
    try std.testing.expectEqual(@as(u32, 0x1111), try core.register(.r0));
    try std.testing.expectEqual(@as(u32, 0), try core.register(.r1));
    try std.testing.expectEqual(@as(u32, 0), try core.register(.r2));
    try std.testing.expectEqual(@as(u32, 0), try core.register(.r3));
    try std.testing.expectEqual(@as(u32, 0), try core.register(.r12));
    try std.testing.expectEqual(@as(u32, 0x4444), try core.register(.lr));
    try std.testing.expectEqual(@as(usize, 1), clears.stepped);
    try std.testing.expect(!clears.quiet());
}
