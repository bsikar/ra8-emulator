//! Two cores in one session: `core N` swaps which one the commands drive,
//! and the one not selected holds where it stopped.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const script = ra8.core.script;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const Engine = ra8.core.engine.Engine;

const base: u32 = memmap.sram_base;
// CPU0: two nops, then a branch to self.
const program0 = [_]u8{ 0x00, 0xbf, 0x00, 0xbf, 0xfe, 0xe7 };
// CPU1: movs r0,#1; movs r0,#2; then a branch to self.
const program1 = [_]u8{ 0x01, 0x20, 0x02, 0x20, 0xfe, 0xe7 };

const Cpu = struct {
    core: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,

    fn open(self: *Cpu, program: []const u8) !void {
        self.machine = .{};
        self.core = try Engine.open();
        errdefer self.core.close();
        try self.core.mapBoardRam();
        try self.core.write(base, program);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.core.handle, &self.driver, false);
    }

    fn slot(self: *Cpu) session.Slot {
        return .{ .core = &self.core, .driver = &self.driver, .entry = base };
    }
};

test "core N swaps the CPU the commands drive, and the other holds" {
    var cpu0: Cpu = undefined;
    try cpu0.open(&program0);
    defer cpu0.core.close();
    var cpu1: Cpu = undefined;
    try cpu1.open(&program1);
    defer cpu1.core.close();
    var target = session.Session{ .core = &cpu0.core, .driver = &cpu0.driver, .entry = base, .budget = 50, .other = cpu1.slot() };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const text =
        \\step
        \\core 1
        \\step
        \\step
        \\info registers
        \\core 0
        \\step
        \\core 2
    ;
    _ = try script.play(&target, text, out.writer(), false);
    try std.testing.expectEqualStrings(
        \\0x22000002: nop
        \\Core 1, 0x22000000: movs r0, #1
        \\0x22000002: movs r0, #2
        \\0x22000004: b #0x22000004
        \\r0  0x00000002  r1  0x00000000  r2  0x00000000  r3  0x00000000
        \\r12 0x00000000  sp  0x00000000  lr  0x00000000  pc  0x22000004
        \\Core 0, 0x22000002: nop
        \\0x22000004: b #0x22000004
        \\error: BadCore
        \\
    , out.items);
}

test "a single-core session names core 0 and refuses core 1" {
    var cpu0: Cpu = undefined;
    try cpu0.open(&program0);
    defer cpu0.core.close();
    var target = session.Session{ .core = &cpu0.core, .driver = &cpu0.driver, .entry = base, .budget = 50 };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    _ = try script.play(&target, "core 0\ncore 1\n", out.writer(), false);
    try std.testing.expectEqualStrings("Core 0, 0x22000000: nop\nerror: CoreNotAttached\n", out.items);
}
