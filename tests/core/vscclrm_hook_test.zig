//! Covers src/core/vscclrm_hook.zig with a live Unicorn: VSCCLRM has to be a
//! NOP while CONTROL.SFPA is clear, clear its run when it is set, and let the
//! run carry on from the next instruction either way.
const std = @import("std");
const ra8 = @import("ra8");
const c = ra8.core.c;
const engine = ra8.core.engine;
const hook = ra8.core.csel.vscclrm_hook;

const base: u32 = 0x0200_0000;
const sfpa: u32 = 1 << 3;
const fpca: u32 = 1 << 2;

/// vscclrm {s0-s15, vpr} / movs r1, #1 / bkpt.
const clear_then_move = [_]u8{ 0x9F, 0xEC, 0x10, 0x0A, 0x01, 0x21, 0x00, 0xBE };

fn coreWith(code: []const u8) !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.map(base, 0x1000);
    try core.write(base, code);
    try hook.hookAt(core.handle, base);
    return core;
}

fn write(core: engine.Engine, which: c_int, value: u32) !void {
    var scratch = value;
    if (c.uc.uc_reg_write(core.handle, which, &scratch) != c.uc.UC_ERR_OK) return error.Write;
}

fn read(core: engine.Engine, which: c_int) !u32 {
    var value: u32 = 0;
    if (c.uc.uc_reg_read(core.handle, which, &value) != c.uc.UC_ERR_OK) return error.Read;
    return value;
}

test "decode takes the veneer's vscclrm and nothing else" {
    const run = hook.decode(0xEC9F, 0x0A10).?;
    try std.testing.expectEqual(@as(u6, 0), run.first);
    try std.testing.expectEqual(@as(u6, 16), run.count);
    try std.testing.expect(hook.decode(0xEC9F, 0x0F10) == null);
    try std.testing.expect(hook.decode(0xE89F, 0x0A10) == null);
}

test "vscclrm with SFPA clear leaves S0 and CONTROL alone" {
    var core = try coreWith(&clear_then_move);
    defer core.close();
    try write(core, c.uc.UC_ARM_REG_S0, 0x3F80_0000);
    try core.setRegister(.r1, 0);
    const control = try read(core, c.uc.UC_ARM_REG_CONTROL);
    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), try read(core, c.uc.UC_ARM_REG_S0));
    try std.testing.expectEqual(control, try read(core, c.uc.UC_ARM_REG_CONTROL));
    try std.testing.expectEqual(@as(u32, 1), try core.register(.r1));
}

test "vscclrm with SFPA set clears its run" {
    var core = try coreWith(&clear_then_move);
    defer core.close();
    try write(core, c.uc.UC_ARM_REG_CONTROL, sfpa | fpca);
    try std.testing.expect(try read(core, c.uc.UC_ARM_REG_CONTROL) & sfpa != 0);
    try write(core, c.uc.UC_ARM_REG_S0, 0x3F80_0000);
    try write(core, c.uc.UC_ARM_REG_S15, 0x4000_0000);
    try write(core, c.uc.UC_ARM_REG_S16, 0x4040_0000);
    try core.setRegister(.r1, 0);
    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0), try read(core, c.uc.UC_ARM_REG_S0));
    try std.testing.expectEqual(@as(u32, 0), try read(core, c.uc.UC_ARM_REG_S15));
    try std.testing.expectEqual(@as(u32, 0x4040_0000), try read(core, c.uc.UC_ARM_REG_S16));
    try std.testing.expectEqual(@as(u32, 1), try core.register(.r1));
}
