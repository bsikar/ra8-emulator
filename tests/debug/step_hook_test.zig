//! The stop machine driven by Unicorn's hooks on a live engine: every stop
//! kind lands on the instruction it should, with that instruction unrun.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const watch_table = ra8.core.watch_table;
const Engine = ra8.core.engine.Engine;

/// Where the fixture program, its stack and its data sit in SRAM.
const layout = struct {
    const code: u32 = memmap.sram_base;
    const call_site: u32 = code + 0x04;
    const after_call: u32 = code + 0x08;
    const store: u32 = code + 0x0A;
    const callee: u32 = code + 0x20;
    const data: u32 = memmap.sram_base + 0x1000;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: usize = 32;
};

/// nop, nop, bl callee, nop, str r2,[r1], then nops up to the callee,
/// which is nop then bx lr.
fn program() [0x24]u8 {
    var bytes: [0x24]u8 = undefined;
    var at: usize = 0;
    while (at < bytes.len) : (at += 2) {
        bytes[at] = 0x00;
        bytes[at + 1] = 0xBF;
    }
    @memcpy(bytes[0x04..0x08], &[_]u8{ 0x00, 0xF0, 0x0C, 0xF8 });
    @memcpy(bytes[0x0A..0x0C], &[_]u8{ 0x0A, 0x60 });
    @memcpy(bytes[0x22..0x24], &[_]u8{ 0x70, 0x47 });
    return bytes;
}

const Fixture = struct {
    engine: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,

    fn open(self: *Fixture) !void {
        self.engine = try Engine.open();
        errdefer self.engine.close();
        try self.engine.mapBoardRam();
        const bytes = program();
        try self.engine.write(layout.code, &bytes);
        try self.engine.setRegister(.sp, layout.stack);
        try self.engine.setRegister(.r1, layout.data);
        try self.engine.setRegister(.r2, 0x55);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.engine.handle, &self.driver, true);
    }

    fn run(self: *Fixture, from: u32) !u32 {
        self.driver.arm();
        _ = try self.engine.runChunk(from, layout.budget, null);
        return self.engine.register(.pc);
    }
};

test "a step stops on the next instruction" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    fixture.machine.step();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.code + 2, pc);
    try std.testing.expect(fixture.driver.last.? == .stepped);
}

test "running stops on a break with the break unrun" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    const id = try fixture.machine.breaks.add(.{ .address = layout.after_call });
    fixture.machine.proceed();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.after_call, pc);
    try std.testing.expectEqual(id, fixture.driver.last.?.breakpoint);
}

test "a step over a BL runs the callee and stops after the call" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    fixture.machine.stepOver();
    const pc = try fixture.run(layout.call_site);
    try std.testing.expectEqual(layout.after_call, pc);
    try std.testing.expect(fixture.driver.last.? == .stepped);
}

test "a step out returns to the caller" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    try fixture.engine.setRegister(.lr, layout.after_call | 1);
    fixture.machine.stepOut(layout.after_call | 1, layout.stack);
    const pc = try fixture.run(layout.callee);
    try std.testing.expectEqual(layout.after_call, pc);
    try std.testing.expect(fixture.driver.last.? == .stepped);
}

test "a watched store stops after the storing instruction" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    const id = try fixture.machine.watches.add(try watch_table.Watch.span(layout.data, 4, .write));
    fixture.machine.proceed();
    const pc = try fixture.run(layout.store);
    try std.testing.expectEqual(layout.store + 2, pc);
    const hit = fixture.driver.last.?.watchpoint;
    try std.testing.expectEqual(id, hit.id);
    try std.testing.expectEqual(layout.data, hit.address);
    try std.testing.expectEqual(@as(u32, 0x55), try fixture.engine.readWord(layout.data));
}

test "a run with nothing to stop it spends its budget" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    fixture.machine.proceed();
    _ = try fixture.run(layout.store + 2);
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), fixture.driver.last);
}

// str r1,[r0,#8] (FP_COMP0); str r2,[r0] (FP_CTRL); ldr r3,[r0]; nop; nop.
test "firmware that programs the FPB halts on its comparator and reads FP_CTRL back" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    const fpb = ra8.core.fpb;
    try fixture.engine.write(layout.code, &[_]u8{ 0x81, 0x60, 0x02, 0x60, 0x03, 0x68, 0x00, 0xBF, 0x00, 0xBF });
    try fixture.engine.setRegister(.r0, fpb.base);
    try fixture.engine.setRegister(.r1, (layout.code + 8) | fpb.comp_enable);
    try fixture.engine.setRegister(.r2, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    fixture.machine.begin();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.code + 8, pc);
    try std.testing.expectEqual(@as(usize, 0), fixture.driver.last.?.unit_break);
    const ctrl = try fixture.engine.register(.r3);
    try std.testing.expectEqual(fpb.ctrl_bits.enable, ctrl & 0x3);
    try std.testing.expectEqual(@as(u32, 1), ctrl >> 28);
}

// str r1,[r0,#0x20] (DWT_COMP0); str r2,[r0,#0x28] (DWT_FUNCTION0); str r4,[r3]; nop; nop.
test "firmware that arms a DWT write comparator halts after the store and sees MATCHED" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    fixture.machine.dwt.trcena = true;
    try fixture.open();
    defer fixture.engine.close();
    const dwt = ra8.core.dwt;
    const function = dwt.match.data_write | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift);
    try fixture.engine.write(layout.code, &[_]u8{ 0x01, 0x62, 0x82, 0x62, 0x1C, 0x60, 0x00, 0xBF, 0x00, 0xBF });
    try fixture.engine.setRegister(.r0, dwt.base);
    try fixture.engine.setRegister(.r1, layout.data);
    try fixture.engine.setRegister(.r2, function);
    try fixture.engine.setRegister(.r3, layout.data);
    try fixture.engine.setRegister(.r4, 0x77);
    fixture.machine.begin();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.code + 6, pc);
    try std.testing.expectEqual(@as(usize, 0), fixture.driver.last.?.unit_watch);
    try std.testing.expectEqual(@as(u32, 0x77), try fixture.engine.readWord(layout.data));
    const seen = try fixture.engine.readWord(dwt.base + dwt.offsets.function0);
    const id0 = dwt.id.of(0) << dwt.function_bits.id_shift;
    try std.testing.expectEqual(id0 | function | dwt.function_bits.matched, seen);
}

// str r1,[r0,#0x30] (DWT_COMP1); str r2,[r0,#0x38] (DWT_FUNCTION1); ldr r5,[r3]; nop; nop.
test "firmware that arms a DWT read Data Value comparator halts after the load that reads it" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    fixture.machine.dwt.trcena = true;
    try fixture.open();
    defer fixture.engine.close();
    const dwt = ra8.core.dwt;
    const function = dwt.match.data_value_read | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift);
    try fixture.engine.write(layout.code, &[_]u8{ 0x01, 0x63, 0x82, 0x63, 0x1D, 0x68, 0x00, 0xBF, 0x00, 0xBF });
    try fixture.engine.write(layout.data, &[_]u8{ 0x34, 0x12, 0x00, 0x00 });
    try fixture.engine.setRegister(.r0, dwt.base);
    try fixture.engine.setRegister(.r1, 0x1234);
    try fixture.engine.setRegister(.r2, function);
    try fixture.engine.setRegister(.r3, layout.data);
    fixture.machine.begin();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.code + 6, pc);
    try std.testing.expectEqual(@as(usize, 1), fixture.driver.last.?.unit_watch);
    try std.testing.expectEqual(@as(u32, 0x1234), try fixture.engine.register(.r5));
}

// str r5,[r6] (TER); str r5,[r7] (TCR); strb r1,[r0]; strb r2,[r0]; ldr r3,[r0]; nop.
test "firmware printing through ITM port 0 leaves its text with the debug core" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    const itm = ra8.core.itm;
    try fixture.engine.write(layout.code, &[_]u8{ 0x35, 0x60, 0x3D, 0x60, 0x01, 0x70, 0x02, 0x70, 0x03, 0x68, 0x00, 0xBF });
    try fixture.engine.setRegister(.r0, itm.base);
    try fixture.engine.setRegister(.r1, 'H');
    try fixture.engine.setRegister(.r2, 'i');
    try fixture.engine.setRegister(.r3, 0);
    try fixture.engine.setRegister(.r5, 1);
    try fixture.engine.setRegister(.r6, itm.base + itm.offsets.ter);
    try fixture.engine.setRegister(.r7, itm.base + itm.offsets.tcr);
    _ = try fixture.machine.breaks.add(.{ .address = layout.code + 10 });
    fixture.machine.begin();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.code + 10, pc);
    try std.testing.expectEqualStrings("Hi", fixture.machine.itm.output());
    try std.testing.expectEqual(itm.fifo_ready, try fixture.engine.register(.r3));
}

// ldr r3,[r0] (DHCSR); str r1,[r0] (keyed C_HALT); nop; nop.
test "firmware sees the debugger in DHCSR and halts itself with a keyed C_HALT" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    const dcb = ra8.core.dcb;
    const bits = dcb.dhcsr_bits;
    try fixture.engine.write(layout.code, &[_]u8{ 0x03, 0x68, 0x01, 0x60, 0x00, 0xBF, 0x00, 0xBF });
    try fixture.engine.setRegister(.r0, dcb.base);
    try fixture.engine.setRegister(.r1, (bits.key << bits.key_shift) | bits.c_halt | bits.c_debugen);
    fixture.machine.begin();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.code + 4, pc);
    try std.testing.expect(fixture.driver.last.? == .halt_requested);
    try std.testing.expectEqual(bits.c_debugen | bits.s_regrdy, try fixture.engine.register(.r3));
}

// str r1,[r0,#8] (FP_COMP0); str r2,[r0] (FP_CTRL); nop x4. Break at +8.
test "with halting debug off and MON_EN set, an FPB match pends DebugMonitor and latches DFSR" {
    var fixture: Fixture = undefined;
    fixture.machine = .{ .halting = false };
    try fixture.open();
    defer fixture.engine.close();
    const fpb = ra8.core.fpb;
    const dcb = ra8.core.dcb;
    try fixture.engine.write(layout.code, &[_]u8{ 0x81, 0x60, 0x02, 0x60, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF });
    try fixture.engine.writeWord(dcb.demcr_address, dcb.demcr_bits.mon_en);
    try fixture.engine.setRegister(.r0, fpb.base);
    try fixture.engine.setRegister(.r1, (layout.code + 6) | fpb.comp_enable);
    try fixture.engine.setRegister(.r2, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    _ = try fixture.machine.breaks.add(.{ .address = layout.code + 8 });
    fixture.machine.begin();
    const pc = try fixture.run(layout.code);
    try std.testing.expectEqual(layout.code + 8, pc);
    try std.testing.expect(fixture.driver.last.? == .breakpoint);
    const demcr = try fixture.engine.readWord(dcb.demcr_address);
    try std.testing.expect(demcr & dcb.demcr_bits.mon_pend != 0);
    try std.testing.expect(try fixture.engine.readWord(dcb.dfsr_address) & dcb.dfsr_bits.bkpt != 0);
    try std.testing.expectEqual(dcb.dhcsr_bits.s_regrdy, try fixture.engine.readWord(dcb.base));
}

// str r1,[r0] (DEMCR, TRCENA set); strb r2,[r0] (byte 0 only); nop.
test "firmware storing DEMCR.TRCENA turns the DWT on, and a byte store elsewhere leaves it" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    try fixture.open();
    defer fixture.engine.close();
    const dcb = ra8.core.dcb;
    try fixture.engine.write(layout.code, &[_]u8{ 0x01, 0x60, 0x02, 0x70, 0x00, 0xBF });
    try fixture.engine.setRegister(.r0, dcb.demcr_address);
    try fixture.engine.setRegister(.r1, dcb.demcr_bits.trcena);
    try fixture.engine.setRegister(.r2, 0);
    _ = try fixture.run(layout.code);
    try std.testing.expect(fixture.machine.dwt.trcena);
}

// strb r2,[r0,#3] (DEMCR's top byte, TRCENA clear); nop.
test "firmware clearing DEMCR.TRCENA with a byte store turns the DWT off" {
    var fixture: Fixture = undefined;
    fixture.machine = .{};
    fixture.machine.dwt.trcena = true;
    try fixture.open();
    defer fixture.engine.close();
    const dcb = ra8.core.dcb;
    try fixture.engine.write(layout.code, &[_]u8{ 0xC2, 0x70, 0x00, 0xBF });
    try fixture.engine.setRegister(.r0, dcb.demcr_address);
    try fixture.engine.setRegister(.r2, 0);
    _ = try fixture.run(layout.code);
    try std.testing.expect(!fixture.machine.dwt.trcena);
}
