//! Covers src/core/tt_hook.zig with a live Unicorn: the hook has to answer
//! from the board's SAU before the CPU model's own TT runs, and let the run
//! carry on from the next instruction.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const sau = ra8.periph.sau;
const hook = ra8.core.csel.tt_hook;
const field = hook.tt.field;

/// Secure code lives at `base`, which the SAU below leaves Secure.
const base: u32 = 0x0200_0000;
const enable: u32 = 1 << 0;

/// ttat r3, r0 / movs r1, #1 / bkpt.
const ttat_then_move = [_]u8{ 0x40, 0xE8, 0xC0, 0xF3, 0x01, 0x21, 0x00, 0xBE };
/// tta r2, r2 / bkpt: Rd the same register as Rn.
const tta_in_place = [_]u8{ 0x42, 0xE8, 0x80, 0xF2, 0x00, 0xBE };

fn bootMap() sau.Sau {
    var unit = sau.Sau{ .ctrl = enable };
    unit.table[0] = sau.Region.fromPair(0x3210_0000, 0x3217_FFE0 | 1);
    return unit;
}

fn coreWith(code: []const u8, unit: *const sau.Sau) !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.map(base, 0x1000);
    try core.write(base, code);
    try hook.hookAt(core.handle, base, unit);
    return core;
}

test "ttat on a Non-secure buffer reports S clear and the run carries on" {
    const unit = bootMap();
    var core = try coreWith(&ttat_then_move, &unit);
    defer core.close();
    try core.setRegister(.r0, 0x3210_8EFC);
    try core.setRegister(.r1, 0);
    _ = try core.run(base, 16, .{});
    const word = try core.register(.r3);
    try std.testing.expectEqual(@as(u32, 0), word & field.s);
    try std.testing.expect(word & field.nsrw != 0);
    try std.testing.expect(word & field.srvalid != 0);
    // The movs after it ran, so the PC moved on rather than repeating.
    try std.testing.expectEqual(@as(u32, 1), try core.register(.r1));
}

test "tta on Secure memory reports S set" {
    const unit = bootMap();
    var core = try coreWith(&tta_in_place, &unit);
    defer core.close();
    try core.setRegister(.r2, 0x0200_0100);
    _ = try core.run(base, 16, .{});
    const word = try core.register(.r2);
    try std.testing.expect(word & field.s != 0);
    try std.testing.expectEqual(@as(u32, 0), word & field.srvalid);
}
