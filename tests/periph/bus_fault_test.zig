//! Tests for src/periph/bus_fault.zig.

const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const bus = ra8.periph.fault_status.bus;
const Nvic = ra8.periph.nvic.Nvic;

/// PPB words in a map and registers in an array, enough for a fault entry.
const FakeCore = struct {
    const Name = enum { pc, sp, lr, r0, r1, r2, r3, r12, xpsr, primask, psp };

    words: std.AutoHashMap(u32, u32),
    registers: std.EnumArray(Name, u32) = std.EnumArray(Name, u32).initFill(0),

    fn init() !FakeCore {
        var core = FakeCore{ .words = std.AutoHashMap(u32, u32).init(std.testing.allocator) };
        try core.writeWord(memmap.scb.vtor, 0x2200_0000);
        var number: u32 = 0;
        while (number < 16) : (number += 1) {
            try core.writeWord(0x2200_0000 + 4 * number, 0x2200_1000 + 0x100 * number + 1);
        }
        try core.setRegister(.sp, 0x2200_8000);
        return core;
    }

    fn deinit(self: *FakeCore) void {
        self.words.deinit();
    }

    pub fn readWord(self: *FakeCore, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakeCore, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }

    pub fn register(self: *FakeCore, which: Name) !u32 {
        return self.registers.get(which);
    }

    pub fn setRegister(self: *FakeCore, which: Name, value: u32) !void {
        self.registers.set(which, value);
    }
};

const busfaultena: u32 = 1 << 17;
const fault_pc: u32 = 0x2200_0400;

test "a refused load latches PRECISERR and BFARVALID with the address" {
    const owed = bus.latch(.read, 0x6000_0010);
    try std.testing.expectEqual(@as(u32, (1 << 9) | (1 << 15)), owed.cfsr);
    try std.testing.expectEqual(@as(?u32, 0x6000_0010), owed.address);
    try std.testing.expectEqual(owed.cfsr, bus.latch(.write, 0).cfsr);
}

test "a refused fetch latches IBUSERR and leaves BFAR alone" {
    const owed = bus.latch(.fetch, 0x6000_0010);
    try std.testing.expectEqual(@as(u32, 1 << 8), owed.cfsr);
    try std.testing.expect(owed.address == null);
}

test "an enabled BusFault vectors to exception 5 with BFAR set" {
    var core = try FakeCore.init();
    defer core.deinit();
    try core.writeWord(memmap.scb.shcsr, busfaultena);
    var unit = Nvic{};
    const taken = try bus.raise(&core, &unit, .write, 0x6000_0010, fault_pc);
    try std.testing.expectEqual(@as(u16, 5), taken.number);
    try std.testing.expect(!taken.escalated);
    try std.testing.expectEqual(@as(u32, 0x2200_1500), try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x6000_0010), try core.readWord(bus.bfar));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.hfsr));
    // The faulting instruction is the stacked return address.
    const sp = try core.register(.sp);
    try std.testing.expectEqual(fault_pc, try core.readWord(sp + 24));
}

test "a disabled BusFault escalates to HardFault with FORCED and keeps BFSR" {
    var core = try FakeCore.init();
    defer core.deinit();
    var unit = Nvic{};
    const taken = try bus.raise(&core, &unit, .read, 0x6000_0020, fault_pc);
    try std.testing.expectEqual(@as(u16, 3), taken.number);
    try std.testing.expect(taken.escalated);
    try std.testing.expectEqual(@as(u32, 0x2200_1300), try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 1 << 30), try core.readWord(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u32, (1 << 9) | (1 << 15)), try core.readWord(memmap.scb.cfsr));
}

test "a BusFault inside a handler it cannot preempt escalates" {
    var core = try FakeCore.init();
    defer core.deinit();
    try core.writeWord(memmap.scb.shcsr, busfaultena);
    try core.writeWord(memmap.scb.shpr1, 0x0000_8000);
    var unit = Nvic{};
    unit.active[0] = .{ .number = 16, .priority = 0x40 };
    unit.depth = 1;
    const taken = try bus.raise(&core, &unit, .write, 0x6000_0030, fault_pc);
    try std.testing.expect(taken.escalated);
    try std.testing.expectEqual(@as(u16, 3), taken.number);
}
