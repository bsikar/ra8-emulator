//! A session given a run-loop session takes interrupts while it is being
//! debugged; one without runs the bare engine and never does. PendSV is
//! pended by hand in the per-engine PPB before the run, and a break sits on
//! its handler.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const nvic = ra8.periph.nvic;
const script = ra8.core.script;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const Engine = ra8.core.engine.Engine;

const base: u32 = memmap.sram_base;
const reset: u32 = base + 0x40;
const pendsv: u32 = base + 0x44;
const pendsv_slot: u32 = base + 0x38;
const pendsv_set: u32 = 1 << 28;
// A boundary every few instructions, so one closes well inside the budget.
const boundary: u32 = 10;
// nop; b .   at reset, and the same at the PendSV handler.
const idle_loop = [_]u8{ 0x00, 0xbf, 0xfe, 0xe7 };

const Fixture = struct {
    core: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    interrupts: nvic.Nvic = .{ .vector_base = base },

    fn open(self: *Fixture) !void {
        self.* = .{ .core = try Engine.open() };
        errdefer self.core.close();
        try self.core.mapBoardRam();
        try self.word(base, memmap.sram_base + 0x1_0000);
        try self.word(base + 4, reset | 1);
        try self.word(pendsv_slot, pendsv | 1);
        try self.core.write(reset, &idle_loop);
        try self.core.write(pendsv, &idle_loop);
        try self.word(memmap.scb.icsr, pendsv_set);
        try self.core.resetFromVectorTable(base);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.core.handle, &self.driver, false);
    }

    fn word(self: *Fixture, address: u32, value: u32) !void {
        try self.core.write(address, std.mem.asBytes(&value));
    }

    fn play(self: *Fixture, looped: bool, out: anytype) !void {
        var target = session.Session{ .core = &self.core, .driver = &self.driver, .entry = reset, .budget = 200 };
        if (looped) target.loop = .{ .interrupts = &self.interrupts, .per_boundary = boundary };
        _ = try script.play(&target, "break 0x22000044\nrun\n", out, false);
    }
};

test "under the run loop the debugged core takes a pended PendSV" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.core.close();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try fixture.play(true, out.writer());
    try std.testing.expectEqualStrings("Breakpoint 1 at 0x22000044\nBreakpoint 1, 0x22000044: nop\n", out.items);
}

test "the bare engine never takes it and spends the budget" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.core.close();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try fixture.play(false, out.writer());
    try std.testing.expectEqualStrings("Breakpoint 1 at 0x22000044\nBudget of 200 instructions spent at 0x22000042\n", out.items);
}
