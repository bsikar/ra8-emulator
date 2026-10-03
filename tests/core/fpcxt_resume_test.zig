//! Covers src/core/fpcxt_resume.zig on the Unicorn engine.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const fp = ra8.core.csel.fp_context;
const fpcxt = ra8.core.csel.fpcxt_resume;

const base: u32 = 0x2200_0000;
const stack: u32 = base + 0x800;

/// The two FP transfers of a CMSE entry stub, then a VPR save the resume
/// leaves alone, assembled by arm-none-eabi-as 13.3.rel1.
const stub = [_]u8{
    0x6D, 0xED, 0x81, 0xCF, // ed6d cf81  vstr FPCXTNS, [sp, #-4]!
    0xFD, 0xEC, 0x81, 0xCF, // ecfd cf81  vldr FPCXTNS, [sp], #4
    0x6D, 0xED, 0x81, 0x8F, // ed6d 8f81  vstr VPR, [sp, #-4]!
};

fn stopAt(core: engine.Engine, pc: u32) !engine.Fault {
    const taken = (try core.runChunk(pc, 1, null)).?;
    try std.testing.expectEqual(pc, taken.pc);
    return taken;
}

test "the entry stub's save and restore run and resume after each" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &stub);
    try core.setRegister(.sp, stack);
    try core.setRegister(.control, fp.control_fpca | fp.control_sfpa);
    try core.setRegister(.fpscr, 0x0300_0000);

    const save = try stopAt(core, base);
    try std.testing.expectEqual(@as(?u32, base + 4), try fpcxt.raised(core, save));
    try std.testing.expectEqual(stack - 4, try core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0x8300_0000), try core.readWord(stack - 4));

    try core.writeWord(stack - 4, 0x0000_0010);
    const restore = try stopAt(core, base + 4);
    try std.testing.expectEqual(@as(?u32, base + 8), try fpcxt.raised(core, restore));
    try std.testing.expectEqual(stack, try core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0x0000_0010), try core.register(.fpscr));
    try std.testing.expectEqual(@as(u32, 0), try core.register(.control) & fp.control_sfpa);
}

test "a stop that is not one of these transfers is left alone" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &stub);
    try core.setRegister(.sp, stack);
    const vpr = try stopAt(core, base + 8);
    try std.testing.expectEqual(@as(?u32, null), try fpcxt.raised(core, vpr));
    try std.testing.expectEqual(stack, try core.register(.sp));
}
