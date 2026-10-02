//! Both cores debugged over one compiled program: break, step, registers
//! and memory on CPU0, then the same on CPU1, then back to CPU0 where it
//! stopped. Each core has its own engine and RAM here, so the counter each
//! one increments is its own, and that independence is what the
//! transcript shows.
//!
//! The program is the one `step_hook_image_test` holds: a Zig function
//! built for thumb-freestanding-eabihf at ReleaseSmall, linked at the start
//! of SRAM, with its vector table first.
//!
//!   target(x):  ldr r1,=counter; ldr r2,[r1]; add r0,r2; str r0,[r1]; bx lr
//!   reset():    calls target(0..4) in a loop, then target(1) forever
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const script = ra8.core.script;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const Engine = ra8.core.engine.Engine;

const base: u32 = memmap.sram_base;
const bytes = [_]u8{
    0x00, 0x00, 0x01, 0x22, 0x19, 0x00, 0x00, 0x22, 0x02, 0x49, 0x0a, 0x68, 0x10,
    0x44, 0x08, 0x60, 0x70, 0x47, 0x00, 0xbf, 0x54, 0x00, 0x00, 0x22, 0x10, 0xb5,
    0x00, 0x24, 0x05, 0x2c, 0x04, 0xd0, 0x20, 0x46, 0xff, 0xf7, 0xf1, 0xff, 0x01,
    0x34, 0xf8, 0xe7, 0x01, 0x20, 0xff, 0xf7, 0xec, 0xff, 0xfb, 0xe7, 0x70, 0x47,
};

const Cpu = struct {
    core: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,

    fn open(self: *Cpu) !void {
        self.machine = .{};
        self.core = try Engine.open();
        errdefer self.core.close();
        try self.core.mapBoardRam();
        try self.core.write(base, &bytes);
        try self.core.resetFromVectorTable(base);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.core.handle, &self.driver, true);
    }

    fn slot(self: *Cpu) !session.Slot {
        return .{ .core = &self.core, .driver = &self.driver, .entry = try self.core.register(.pc) };
    }
};

const commands =
    \\# CPU0: stop in target on its third call, look, step one line
    \\break 0x22000008 3
    \\run
    \\info registers
    \\step
    \\x 0x22000054 1
    \\# CPU1 starts from its own reset and stops on its first call
    \\core 1
    \\tbreak 0x22000008
    \\run
    \\step
    \\step
    \\step
    \\x 0x22000054 1
    \\info registers
    \\# back to CPU0, where it was left
    \\core 0
    \\continue
    \\x 0x22000054 1
    \\core 1
    \\continue
    \\quit
;

// CPU0 stops on target's third call, so r0 is 2 and the counter holds
// 0 + 1. CPU1 stops on its first, with its own counter still 0. Back on
// CPU0 the next arrival is the fourth call, after 0 + 1 + 2. CPU1's
// temporary break went when it stopped, so its continue runs to the budget.
const expected =
    \\(ra8) break 0x22000008 3
    \\Breakpoint 1 at 0x22000008, arrival 3
    \\(ra8) run
    \\Breakpoint 1, 0x22000008: ldr r1, [pc, #8]
    \\(ra8) info registers
    \\r0  0x00000002  r1  0x22000054  r2  0x00000000  r3  0x00000000
    \\r12 0x00000000  sp  0x2200FFF8  lr  0x22000027  pc  0x22000008
    \\(ra8) step
    \\0x2200000A: ldr r2, [r1]
    \\(ra8) x 0x22000054 1
    \\0x22000054: 0x00000001
    \\(ra8) core 1
    \\Core 1, 0x22000018: push {r4, lr}
    \\(ra8) tbreak 0x22000008
    \\Temporary breakpoint 1 at 0x22000008
    \\(ra8) run
    \\Temporary breakpoint 1, 0x22000008: ldr r1, [pc, #8]
    \\(ra8) step
    \\0x2200000A: ldr r2, [r1]
    \\(ra8) step
    \\0x2200000C: add r0, r2
    \\(ra8) step
    \\0x2200000E: str r0, [r1]
    \\(ra8) x 0x22000054 1
    \\0x22000054: 0x00000000
    \\(ra8) info registers
    \\r0  0x00000000  r1  0x22000054  r2  0x00000000  r3  0x00000000
    \\r12 0x00000000  sp  0x2200FFF8  lr  0x22000027  pc  0x2200000E
    \\(ra8) core 0
    \\Core 0, 0x2200000A: ldr r2, [r1]
    \\(ra8) continue
    \\Breakpoint 1, 0x22000008: ldr r1, [pc, #8]
    \\(ra8) x 0x22000054 1
    \\0x22000054: 0x00000003
    \\(ra8) core 1
    \\Core 1, 0x2200000E: str r0, [r1]
    \\(ra8) continue
    \\Budget of 400 instructions spent at 0x22000010
    \\(ra8) quit
    \\
;

test "a script debugs both cores over a compiled program" {
    var cpu0: Cpu = undefined;
    try cpu0.open();
    defer cpu0.core.close();
    var cpu1: Cpu = undefined;
    try cpu1.open();
    defer cpu1.core.close();
    const first = try cpu0.slot();
    var target = session.Session{ .core = first.core, .driver = first.driver, .entry = first.entry, .budget = 400, .other = try cpu1.slot() };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    _ = try script.play(&target, commands, out.writer(), true);
    try std.testing.expectEqualStrings(expected, out.items);
}
