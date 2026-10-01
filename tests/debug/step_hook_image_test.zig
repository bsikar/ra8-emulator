//! The stop machine driven over a compiled program rather than hand-placed
//! nops: every stop kind on real compiler output, with real calls, a real
//! stack frame and a counter in RAM.
//!
//! The program is a Zig function built for thumb-freestanding-eabihf at
//! ReleaseSmall and linked at the start of SRAM. Its bytes are kept here as
//! the fixture, with the addresses its disassembly gives:
//!
//!   target(x):  ldr r1,=counter; ldr r2,[r1]; add r0,r2; str r0,[r1]; bx lr
//!   reset():    calls target(0..4) in a loop, then target(1) forever
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const watch_table = ra8.core.watch_table;
const Engine = ra8.core.engine.Engine;

const image = struct {
    const base: u32 = memmap.sram_base;
    const target: u32 = base + 0x08;
    const target_load: u32 = base + 0x0A;
    const target_add: u32 = base + 0x0C;
    const target_store: u32 = base + 0x0E;
    const target_return: u32 = base + 0x10;
    const reset: u32 = base + 0x18;
    const loop_call: u32 = base + 0x22;
    const after_loop_call: u32 = base + 0x26;
    const counter: u32 = base + 0x54;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: usize = 400;
    const bytes = [_]u8{
        0x00, 0x00, 0x01, 0x22, 0x19, 0x00, 0x00, 0x22, 0x02, 0x49, 0x0a, 0x68, 0x10,
        0x44, 0x08, 0x60, 0x70, 0x47, 0x00, 0xbf, 0x54, 0x00, 0x00, 0x22, 0x10, 0xb5,
        0x00, 0x24, 0x05, 0x2c, 0x04, 0xd0, 0x20, 0x46, 0xff, 0xf7, 0xf1, 0xff, 0x01,
        0x34, 0xf8, 0xe7, 0x01, 0x20, 0xff, 0xf7, 0xec, 0xff, 0xfb, 0xe7, 0x70, 0x47,
    };
};

const Fixture = struct {
    engine: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,

    fn open(self: *Fixture) !void {
        self.machine = .{};
        self.engine = try Engine.open();
        errdefer self.engine.close();
        try self.engine.mapBoardRam();
        try self.engine.write(image.base, &image.bytes);
        try self.engine.setRegister(.sp, image.stack);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.engine.handle, &self.driver, true);
    }

    /// Run from `from` until the machine stops it or the budget is spent,
    /// and say where the program counter was left.
    fn run(self: *Fixture, from: u32) !u32 {
        self.driver.arm();
        _ = try self.engine.runChunk(from, image.budget, null);
        return self.engine.register(.pc);
    }

    /// Carry on from wherever the last stop left the program counter.
    fn again(self: *Fixture) !u32 {
        return self.run(try self.engine.register(.pc));
    }
};

test "continue stops on the third call into target, after two have stored" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    const id = try fixture.machine.breaks.add(.{ .address = image.target, .arrival = 3 });
    fixture.machine.proceed();
    try std.testing.expectEqual(image.target, try fixture.run(image.reset));
    try std.testing.expectEqual(id, fixture.driver.last.?.breakpoint);
    try std.testing.expectEqual(@as(u32, 0 + 1), try fixture.engine.readWord(image.counter));
}

test "a break at an offset inside target stops on the store, unrun" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    _ = try fixture.machine.breaks.add(.{ .address = image.target_store });
    fixture.machine.proceed();
    try std.testing.expectEqual(image.target_store, try fixture.run(image.reset));
    try std.testing.expectEqual(@as(u32, 0), try fixture.engine.readWord(image.counter));
}

test "a step from a break moves one instruction and a second continue resumes past it" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    _ = try fixture.machine.breaks.add(.{ .address = image.target });
    fixture.machine.proceed();
    try std.testing.expectEqual(image.target, try fixture.run(image.reset));
    fixture.machine.step();
    try std.testing.expectEqual(image.target_load, try fixture.again());
    try std.testing.expect(fixture.driver.last.? == .stepped);
    fixture.machine.proceed();
    try std.testing.expectEqual(image.target, try fixture.again());
    try std.testing.expectEqual(@as(u32, 2), fixture.machine.breaks.get(1).?.seen);
}

test "a step over the loop's call runs all of target and lands after the call" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    const id = try fixture.machine.breaks.add(.{ .address = image.loop_call });
    fixture.machine.proceed();
    try std.testing.expectEqual(image.loop_call, try fixture.run(image.reset));
    try fixture.machine.breaks.remove(id);
    fixture.machine.stepOver();
    try std.testing.expectEqual(image.after_loop_call, try fixture.again());
    try std.testing.expect(fixture.driver.last.? == .stepped);
}

test "a step out of target returns to the instruction after its call" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    const id = try fixture.machine.breaks.add(.{ .address = image.target });
    fixture.machine.proceed();
    try std.testing.expectEqual(image.target, try fixture.run(image.reset));
    try fixture.machine.breaks.remove(id);
    const lr = try fixture.engine.register(.lr);
    fixture.machine.stepOut(lr, try fixture.engine.register(.sp));
    try std.testing.expectEqual(image.after_loop_call, try fixture.again());
}

test "a halt request stops the run before its next instruction" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    fixture.machine.proceed();
    fixture.machine.requestHalt();
    try std.testing.expectEqual(image.reset + 2, try fixture.run(image.reset));
    try std.testing.expect(fixture.driver.last.? == .halt_requested);
}

/// Where each watch kind on the counter leaves the program counter: after
/// the instruction whose access it was, never halfway through it.
fn expectWatchStop(kind: watch_table.Kind, access: watch_table.Access, after: u32) !void {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    _ = try fixture.machine.watches.add(try watch_table.Watch.span(image.counter, 4, kind));
    fixture.machine.proceed();
    try std.testing.expectEqual(after, try fixture.run(image.reset));
    const hit = fixture.driver.last.?.watchpoint;
    try std.testing.expectEqual(image.counter, hit.address);
    try std.testing.expectEqual(access, hit.access);
}

test "a read watch on the counter stops after target loads it" {
    try expectWatchStop(.read, .read, image.target_add);
}

test "a write watch on the counter stops after target stores it" {
    try expectWatchStop(.write, .write, image.target_return);
}

test "an access watch on the counter stops on the first touch, the load" {
    try expectWatchStop(.access, .read, image.target_add);
}
