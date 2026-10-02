//! A script played into a session: echoed behind the prompt, bad lines
//! reported, and nothing after `quit`.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const script = ra8.core.script;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const Engine = ra8.core.engine.Engine;

// Two Thumb nops then a branch to self, at the start of SRAM.
const program = [_]u8{ 0x00, 0xbf, 0x00, 0xbf, 0xfe, 0xe7 };
const base: u32 = memmap.sram_base;

test "a script echoes each command, reports a bad line and stops at quit" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.write(base, &program);
    var machine = stop_machine.Machine{};
    var driver = step_hook.Driver{ .machine = &machine };
    try step_hook.attach(core.handle, &driver, false);
    var target = session.Session{ .core = &core, .driver = &driver, .entry = base, .budget = 50 };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const text =
        \\# walk the nops
        \\step
        \\
        \\  step   # the second
        \\jump 0
        \\quit
        \\step
    ;
    try std.testing.expectEqual(session.Outcome.quit, try script.play(&target, text, out.writer(), true));
    try std.testing.expectEqualStrings(
        \\(ra8) step
        \\0x22000002: nop
        \\(ra8) step   # the second
        \\0x22000004: b #0x22000004
        \\(ra8) jump 0
        \\error: UnknownCommand
        \\(ra8) quit
        \\
    , out.items);
}

test "without echo only the answers are printed, and a script may end without quit" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.write(base, &program);
    var machine = stop_machine.Machine{};
    var driver = step_hook.Driver{ .machine = &machine };
    try step_hook.attach(core.handle, &driver, false);
    var target = session.Session{ .core = &core, .driver = &driver, .entry = base, .budget = 50 };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(session.Outcome.more, try script.play(&target, "step\np 0x22000000\n", out.writer(), false));
    try std.testing.expectEqualStrings("0x22000002: nop\n0x22000000 = 0xBF00BF00 (3204497152)\n", out.items);
}
