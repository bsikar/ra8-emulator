//! The remote protocol's run control and threads against a debugger
//! session, over the same compiled program session_test.zig runs:
//!
//!   target(x):  ldr r1,=counter; ldr r2,[r1]; add r0,r2; str r0,[r1]; bx lr
//!   reset():    calls target(0..4) in a loop, then target(1) forever
const std = @import("std");
const ra8 = @import("ra8");

const dispatch = ra8.core.rsp_dispatch;
const memmap = ra8.core.memmap;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const Engine = ra8.core.engine.Engine;

const image = struct {
    const base: u32 = memmap.sram_base;
    const target: u32 = base + 0x08;
    const reset: u32 = base + 0x18;
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
    session: session.Session = undefined,
    out: [128]u8 = undefined,

    fn open(self: *Fixture, entry: u32) !void {
        self.machine = .{};
        self.engine = try Engine.open();
        errdefer self.engine.close();
        try self.engine.mapBoardRam();
        try self.engine.write(image.base, &image.bytes);
        try self.engine.setRegister(.sp, image.stack);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.engine.handle, &self.driver, true);
        self.session = .{ .core = &self.engine, .driver = &self.driver, .entry = entry, .budget = image.budget };
    }

    fn ask(self: *Fixture, request: []const u8) ![]const u8 {
        const stub = dispatch.Dispatch{ .core = &self.engine, .session = &self.session };
        return stub.answer(request, &self.out);
    }
};

// A break set with Z0 stops c there, and s then moves one instruction.
test "continue stops on a Z0 break and step moves one instruction" {
    var fixture: Fixture = undefined;
    try fixture.open(image.reset);
    defer fixture.engine.close();
    try std.testing.expectEqualStrings("OK", try fixture.ask("Z0,22000008,2"));
    try std.testing.expectEqualStrings("T05thread:1;", try fixture.ask("c"));
    try std.testing.expectEqual(image.target, try fixture.engine.register(.pc));
    try std.testing.expectEqualStrings("T05thread:1;", try fixture.ask("vCont;s:1"));
    try std.testing.expectEqual(image.target + 2, try fixture.engine.register(.pc));
    try std.testing.expectEqualStrings("T05thread:1;", try fixture.ask("?"));
}

// A Z2 watch on the counter stops a continue with the address gdb reads.
test "a write watch stops continue with a watch stop reply" {
    var fixture: Fixture = undefined;
    try fixture.open(image.reset);
    defer fixture.engine.close();
    try std.testing.expectEqualStrings("OK", try fixture.ask("Z2,22000054,4"));
    try std.testing.expectEqualStrings("T05watch:22000054;thread:1;", try fixture.ask("vCont;c"));
    try std.testing.expectEqualStrings("OK", try fixture.ask("z2,22000054,4"));
    try std.testing.expectEqualStrings("OK", try fixture.ask("Z4,22000054,4"));
    try std.testing.expectEqualStrings("T05awatch:22000054;thread:1;", try fixture.ask("c"));
}

// A run that starts somewhere nothing is mapped faults, and gdb hears SIGSEGV.
test "a fault answers T0b" {
    var fixture: Fixture = undefined;
    try fixture.open(0x1000_0001);
    defer fixture.engine.close();
    try std.testing.expectEqualStrings("T0bthread:1;", try fixture.ask("c"));
}

// One core is one thread; a second thread is refused until a second core is attached.
test "threads on a single-core session" {
    var fixture: Fixture = undefined;
    try fixture.open(image.reset);
    defer fixture.engine.close();
    try std.testing.expectEqualStrings("vCont;c;C;s;S", try fixture.ask("vCont?"));
    try std.testing.expectEqualStrings("m1", try fixture.ask("qfThreadInfo"));
    try std.testing.expectEqualStrings("l", try fixture.ask("qsThreadInfo"));
    try std.testing.expectEqualStrings("QC1", try fixture.ask("qC"));
    try std.testing.expectEqualStrings("OK", try fixture.ask("Hg1"));
    try std.testing.expectEqualStrings("OK", try fixture.ask("Hc-1"));
    try std.testing.expectEqualStrings("OK", try fixture.ask("Hg0"));
    try std.testing.expectEqualStrings("E00", try fixture.ask("Hg2"));
    try std.testing.expectEqualStrings("OK", try fixture.ask("T1"));
    try std.testing.expectEqualStrings("E00", try fixture.ask("T2"));
    try std.testing.expectEqualStrings("E00", try fixture.ask("vCont;c:2"));
}

// Reads go to the session's core, so g reflects where a stop left the pc.
test "register reads follow the session" {
    var fixture: Fixture = undefined;
    try fixture.open(image.reset);
    defer fixture.engine.close();
    _ = try fixture.ask("Z0,22000008,2");
    _ = try fixture.ask("c");
    try std.testing.expectEqualStrings("08000022", try fixture.ask("pf"));
}
