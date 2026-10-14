//! The stop machine's hit sets end to end: the Zig core runs real guest
//! programs through the drive, and one slot's collected arrivals reach
//! the report whole (RA8EMU-1160).
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const exception_ram = @import("../../chip/core/cpu/exception/ram.zig");
const Fake = @import("../../chip/core/cpu/exception/fake_source.zig").Fake;
const step_hook = ra8.session.step_hook;
const ZigSession = step_hook.zig.session.ZigSession;
const watch_bus = step_hook.watch.bus;
const Machine = ra8.session.stop_machine.Machine;
const watch_table = ra8.session.watch.table;
const dwt = ra8.chip.periph.dwt;

/// A core booted from the exception RAM, its bus behind the debugger's
/// listening bus, and a session driving it.
const Bench = struct {
    ram: exception_ram.Ram = .{},
    machine: Machine = .{},
    driver: step_hook.Driver = undefined,
    watch: watch_bus.WatchBus = undefined,
    cpu: Cpu = undefined,

    fn open(self: *Bench) !void {
        self.driver = .{ .machine = &self.machine };
        self.watch = .{ .inner = self.ram.view(), .driver = &self.driver };
        self.cpu = try exception_ram.boot(&self.ram);
        self.cpu.bus = self.watch.view();
    }
};

fn session(bench: *Bench) ZigSession {
    return .{ .core = .{ .cpu = &bench.cpu }, .machine = &bench.machine, .budget = 64, .watch = &bench.watch };
}

/// The bus a test writes through to pend an exception, as the real one does.
const PendBus = struct {
    ram: *exception_ram.Ram,
    fake: *Fake,

    fn view(self: *PendBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *PendBus = @ptrCast(@alignCast(ctx));
        try self.ram.view().read(address, into);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *PendBus = @ptrCast(@alignCast(ctx));
        try self.ram.view().write(address, bytes);
        if (address == exception_ram.base + 0x80) self.fake.pending = .{ .number = 11, .priority = 0 };
    }
};

test "a PUSH of four registers lands the whole hit set across disjoint watches" {
    var bench: Bench = .{};
    try bench.open();
    bench.cpu.regs.low[4] = 0x1111_1111;
    bench.cpu.regs.low[5] = 0x2222_2222;
    bench.cpu.regs.low[6] = 0x3333_3333;
    bench.cpu.regs.low[7] = 0x4444_4444;
    bench.ram.putHalf(exception_ram.code, 0xB5F0); // PUSH {r4, r5, r6, r7}
    bench.ram.putHalf(exception_ram.code + 2, 0xBF00); // nop
    var ids: [4]watch_table.Id = undefined;
    var addrs: [4]u32 = undefined;
    for (0..4) |i| {
        addrs[i] = exception_ram.msp_top - 20 + @as(u32, @intCast(i)) * 4;
        ids[i] = try bench.machine.addWatch(try watch_table.Watch.span(addrs[i], 4, .write));
    }
    var live = session(&bench);
    const ended = try live.go(.cont);
    try std.testing.expect(ended == .stop and ended.stop == .watchpoint);
    try std.testing.expectEqual(ids[0], ended.stop.watchpoint.id);
    const hits = bench.machine.arrivals();
    try std.testing.expectEqual(@as(usize, 4), hits.len);
    for (hits, 0..) |arrival, i| {
        try std.testing.expectEqual(ids[i], arrival.watch.id);
        try std.testing.expectEqual(watch_table.Access.write, arrival.watch.access);
    }
    // The stack really holds what the watches saw: the frame is real.
    try std.testing.expectEqual(@as(u32, 0x1111_1111), bench.ram.word(addrs[0]));
    try std.testing.expectEqual(@as(u32, 0x4444_4444), bench.ram.word(addrs[3]));
}

test "a STRD hands two disjoint watches one slot's hit set" {
    var bench: Bench = .{};
    try bench.open();
    bench.cpu.regs.low[0] = 0xAAAA_AAAA;
    bench.cpu.regs.low[1] = 0xBBBB_BBBB;
    bench.cpu.regs.low[4] = exception_ram.base + 0x200;
    bench.ram.putHalf(exception_ram.code, 0xE9C4); // STRD r0, r1, [r4]
    bench.ram.putHalf(exception_ram.code + 2, 0x0100);
    bench.ram.putHalf(exception_ram.code + 4, 0xBF00); // nop
    const low = try bench.machine.addWatch(try watch_table.Watch.span(exception_ram.base + 0x200, 4, .write));
    const high = try bench.machine.addWatch(try watch_table.Watch.span(exception_ram.base + 0x204, 4, .write));
    var live = session(&bench);
    const ended = try live.go(.cont);
    try std.testing.expect(ended == .stop and ended.stop == .watchpoint);
    const hits = bench.machine.arrivals();
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(low, hits[0].watch.id);
    try std.testing.expectEqual(high, hits[1].watch.id);
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), bench.ram.word(exception_ram.base + 0x200));
    try std.testing.expectEqual(@as(u32, 0xBBBB_BBBB), bench.ram.word(exception_ram.base + 0x204));
}

test "a halting DWT data stop lands before a pending interrupt is taken" {
    var bench: Bench = .{};
    try bench.open();
    bench.ram.putHalf(exception_ram.code, 0x6001); // STR r1, [r0]
    bench.ram.putHalf(exception_ram.code + 2, 0xBF00); // nop
    bench.ram.putHalf(exception_ram.code + 4, 0xE7FE); // b .: the main line waits
    bench.ram.putHalf(exception_ram.handler, 0x6002); // STR r2, [r0]
    bench.ram.putHalf(exception_ram.handler + 2, 0x4770); // bx lr
    bench.cpu.regs.low[2] = 0x5555_5555;
    bench.cpu.regs.low[0] = exception_ram.base + 0x80;
    bench.cpu.regs.low[1] = 1 << 11;
    bench.cpu.regs.primask = 0;
    var fake: Fake = .{};
    var pending: PendBus = .{ .ram = &bench.ram, .fake = &fake };
    bench.watch.inner = pending.view();
    bench.cpu.source = fake.source();
    bench.machine.dwt.trcena = true;
    _ = bench.machine.dwt.write(dwt.offsets.comp0, exception_ram.base + 0x80);
    _ = bench.machine.dwt.write(dwt.offsets.function0, dwt.match.data_write | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift));
    var live = session(&bench);
    const ended = try live.go(.cont);
    try std.testing.expect(ended == .stop and ended.stop == .unit_watch);
    // The stop landed in the retire gap: the interrupt is pending but the
    // core has not taken it, so no frame is stacked and the handler never
    // ran.
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
    try std.testing.expect(fake.pending != null);
    try std.testing.expectEqual(exception_ram.code + 2, bench.cpu.regs.pc);
    // Resuming takes the interrupt: the handler runs and its own store
    // replaces what the main line wrote.
    const resumed = try live.go(.cont);
    _ = resumed;
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
    try std.testing.expectEqual(@as(u32, 0x5555_5555), bench.ram.word(exception_ram.base + 0x80));
}

test "a counted break stops on the arrival it asked for" {
    var bench: Bench = .{};
    try bench.open();
    bench.ram.putHalf(exception_ram.code, 0xBF00); // nop
    bench.ram.putHalf(exception_ram.code + 2, 0xE7FD); // b .-6: back to the nop
    const id = try bench.machine.addBreak(.{ .address = exception_ram.code, .arrival = 2 });
    var live = session(&bench);
    const ended = try live.go(.cont);
    try std.testing.expect(ended == .stop and ended.stop == .breakpoint);
    try std.testing.expectEqual(id, ended.stop.breakpoint);
    // The first arrival did not stop the run: the nop ran twice before
    // the stop, and the machine holds the count it reached.
    const point = bench.machine.breaks.get(id).?;
    try std.testing.expectEqual(@as(u32, 2), point.seen);
    try std.testing.expect(point.reached);
}

test "a query of a watched PPB address stays silent, a firmware access does not" {
    var bench: Bench = .{};
    try bench.open();
    bench.ram.putHalf(exception_ram.code, 0x6808); // LDR r0, [r1]
    bench.ram.putHalf(exception_ram.code + 2, 0xBF00); // nop
    bench.cpu.regs.low[1] = exception_ram.scs;
    const id = try bench.machine.addWatch(try watch_table.Watch.span(exception_ram.scs, 4, .access));
    // A debugger read of the watched place is not a guest access: the
    // query path reads the image, not the core's bus.
    var probe: [4]u8 = undefined;
    try bench.ram.view().read(exception_ram.scs, &probe);
    var live = session(&bench);
    const ended = try live.go(.cont);
    try std.testing.expect(ended == .stop and ended.stop == .watchpoint);
    try std.testing.expectEqual(id, ended.stop.watchpoint.id);
    try std.testing.expectEqual(watch_table.Access.read, ended.stop.watchpoint.access);
}

test "a break at the handler stops before the first handler instruction" {
    var bench: Bench = .{};
    try bench.open();
    bench.ram.putHalf(exception_ram.code, 0x6001); // STR r0, [r1]
    bench.ram.putHalf(exception_ram.code + 2, 0xBF00); // nop
    bench.ram.putHalf(exception_ram.handler, 0x6002); // STR r2, [r0]
    bench.cpu.regs.low[0] = exception_ram.base + 0x80;
    bench.cpu.regs.low[1] = 1 << 11;
    bench.cpu.regs.low[2] = 0x5555_5555;
    bench.cpu.regs.primask = 0;
    var fake: Fake = .{};
    var pending: PendBus = .{ .ram = &bench.ram, .fake = &fake };
    bench.watch.inner = pending.view();
    bench.cpu.source = fake.source();
    const id = try bench.machine.addBreak(.{ .address = exception_ram.handler, .arrival = 1 });
    var live = session(&bench);
    const ended = try live.go(.cont);
    try std.testing.expect(ended == .stop and ended.stop == .breakpoint);
    try std.testing.expectEqual(id, ended.stop.breakpoint);
    try std.testing.expectEqual(exception_ram.handler, bench.cpu.regs.pc);
    // The frame is stacked and the handler's own store has not run.
    try std.testing.expectEqual(exception_ram.msp_top - 32, bench.cpu.regs.sp());
    // The handler's store would have replaced it; the word still holds
    // what the main-line store wrote.
    try std.testing.expectEqual(@as(u32, 1 << 11), bench.ram.word(exception_ram.base + 0x80));
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
}
