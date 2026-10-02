//! DebugMonitor end to end: with halting debug off and DEMCR.MON_EN set, a
//! comparator the firmware armed in its FPB pends exception 12, and the
//! run loop under the session enters the handler. A break sits on it.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const dcb = ra8.core.dcb;
const fpb = ra8.core.fpb;
const nvic = ra8.periph.nvic;
const script = ra8.core.script;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const Engine = ra8.core.engine.Engine;

const base: u32 = memmap.sram_base;
const reset: u32 = base + 0x40;
const monitor: u32 = base + 0x48;
const monitor_slot: u32 = base + 12 * 4;
const boundary: u32 = 10;
// nop; b .   at reset, and the same at the DebugMonitor handler.
const idle_loop = [_]u8{ 0x00, 0xbf, 0xfe, 0xe7 };

const Fixture = struct {
    core: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    interrupts: nvic.Nvic = .{ .vector_base = base },

    fn open(self: *Fixture, mon_en: bool) !void {
        self.* = .{ .core = try Engine.open() };
        errdefer self.core.close();
        try self.core.mapBoardRam();
        try self.core.writeWord(base, memmap.sram_base + 0x1_0000);
        try self.core.writeWord(base + 4, reset | 1);
        try self.core.writeWord(monitor_slot, monitor | 1);
        try self.core.write(reset, &idle_loop);
        try self.core.write(monitor, &idle_loop);
        try self.core.writeWord(dcb.demcr_address, if (mon_en) dcb.demcr_bits.mon_en else 0);
        try self.core.resetFromVectorTable(base);
        _ = self.machine.fpb.write(fpb.offsets.comp0, reset | fpb.comp_enable);
        _ = self.machine.fpb.write(fpb.offsets.ctrl, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.core.handle, &self.driver, false);
    }

    fn play(self: *Fixture, out: anytype) !void {
        var target = session.Session{ .core = &self.core, .driver = &self.driver, .entry = reset, .budget = 200 };
        target.loop = .{ .interrupts = &self.interrupts, .per_boundary = boundary };
        _ = try script.play(&target, "halting off\nbreak 0x22000048\nrun\n", out, false);
    }
};

const halting_off = "Halting debug off: debug events on core 0 take DebugMonitor when DEMCR.MON_EN is set.\n";

test "with MON_EN set, an FPB match enters the firmware's DebugMonitor handler" {
    var fixture: Fixture = undefined;
    try fixture.open(true);
    defer fixture.core.close();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try fixture.play(out.writer());
    try std.testing.expectEqualStrings(halting_off ++ "Breakpoint 1 at 0x22000048\nBreakpoint 1, 0x22000048: nop\n", out.items);
    try std.testing.expect(try fixture.core.readWord(memmap.scb.shcsr) & nvic.debug_monitor.shcsr_monitoract != 0);
    try std.testing.expect(try fixture.core.readWord(dcb.demcr_address) & dcb.demcr_bits.mon_pend == 0);
}

test "with MON_EN clear, the same match is dropped and the handler never runs" {
    var fixture: Fixture = undefined;
    try fixture.open(false);
    defer fixture.core.close();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try fixture.play(out.writer());
    try std.testing.expectEqualStrings(halting_off ++ "Breakpoint 1 at 0x22000048\nBudget of 200 instructions spent at 0x22000042\n", out.items);
}
