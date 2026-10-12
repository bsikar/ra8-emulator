//! Covers src/chip/core/cpu/reset.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const reset = ra8.chip.core.cpu.reset;

const Table = struct {
    words: []const u32,

    fn view(self: *Table) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Table = @ptrCast(@alignCast(ctx));
        const at = address / 4;
        if (into.len != 4 or address % 4 != 0 or at >= self.words.len) return bus.Error.Unmapped;
        std.mem.writeInt(u32, into[0..4], self.words[at], .little);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

test "reset loads MSP and the handler and sets T from bit 0" {
    var table: Table = .{ .words = &.{ 0x2200_0000, 0x0200_0401 } };
    var r: regs.Regs = .{ .psp = 0x1234, .control = 3 };
    try reset.fromVectorTable(&r, table.view(), 0);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), r.msp);
    try std.testing.expectEqual(@as(u32, 0x0200_0400), r.pc);
    try std.testing.expectEqual(regs.xpsr_bits.thumb, r.xpsr);
    try std.testing.expectEqual(reset.lr_at_reset, r.lr);
    try std.testing.expectEqual(@as(u32, 0), r.control);
    try std.testing.expectEqual(@as(u32, 0), r.psp);
}

test "an even reset handler leaves T clear" {
    var table: Table = .{ .words = &.{ 0x2200_0000, 0x0200_0400 } };
    var r: regs.Regs = .{};
    try reset.fromVectorTable(&r, table.view(), 0);
    try std.testing.expectEqual(@as(u32, 0), r.xpsr & regs.xpsr_bits.thumb);
}

test "a vector table nothing answers for fails the reset" {
    var table: Table = .{ .words = &.{0x2200_0000} };
    var r: regs.Regs = .{};
    try std.testing.expectError(bus.Error.Unmapped, reset.fromVectorTable(&r, table.view(), 0));
}

test "reset re-arms both stack low-water marks" {
    var table: Table = .{ .words = &.{ 0x2200_2000, 0x0200_0401 } };
    var r: regs.Regs = .{ .low_msp = 0x2200_0100, .low_psp = 0x2200_0200 };
    try reset.fromVectorTable(&r, table.view(), 0);
    try std.testing.expectEqual(@as(u32, 0x2200_2000), r.low_msp);
    try std.testing.expectEqual(regs.never_low, r.low_psp);
}

test "CPU foundation warm reset clears security FP exclusives and keeps cumulative slots" {
    const fixture = @import("exception/ram.zig");
    var ram = fixture.Ram{};
    ram.putHalf(fixture.code, 0xBF00);
    var cpu = try fixture.boot(&ram);
    try std.testing.expect(cpu.step() == null);
    cpu.banked.current = .non_secure;
    cpu.banked.other.msp = 0x2000_1000;
    cpu.banked.other.primask = 1;
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.context.fpcar = fixture.base + 0x200;
    cpu.fp.bank.s[0] = 0xABCD;
    cpu.exclusive = fixture.base;
    cpu.entering_non_secure = true;
    cpu.waiting = .event;
    cpu.event = true;
    cpu.secure_faults = 7;
    cpu.raised = 11;
    try cpu.reset(fixture.base);
    try std.testing.expectEqual(ra8.chip.core.banked.State.secure, cpu.banked.current);
    try std.testing.expect(std.meta.eql(ra8.chip.core.banked.Banked{}, cpu.banked));
    try std.testing.expect(std.meta.eql(ra8.chip.core.cpu.fpu.state.State{}, cpu.fp));
    try std.testing.expect(cpu.exclusive == null);
    try std.testing.expect(cpu.waiting == null and !cpu.event);
    try std.testing.expect(cpu.raised == null and !cpu.entering_non_secure);
    try std.testing.expectEqual(@as(u32, 0), cpu.secure_faults);
    try std.testing.expectEqual(@as(u64, 1), cpu.retired);
    try std.testing.expectEqual(@as(u64, 1), cpu.slots);
    try std.testing.expectEqual(@as(u64, 0), cpu.sync_entries);
    try std.testing.expect(cpu.step() == null);
    try std.testing.expectEqual(@as(u64, 2), cpu.slots);
}

test "CPU foundation warm reset prevents stale IRQ and banked system pends before handler" {
    const fixture = @import("exception/ram.zig");
    const memmap = ra8.chip.core.memmap;
    var ram = fixture.Ram{};
    ram.putHalf(fixture.code, 0xBF00);
    var cpu = try fixture.boot(&ram);
    var nvic = ra8.chip.core.cpu.exception.nvic_source.NvicSource{ .banked = &cpu.banked };
    cpu.source = nvic.source();
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    ram.putWord(memmap.nvic.iser, 1);
    ram.putWord(memmap.nvic.ispr, 1);
    ram.putWord(memmap.scb.vtor, fixture.base);
    ram.putWord(memmap.scb.icsr + 0x20000, (1 << 26) | (1 << 28));
    ram.putWord(memmap.syst.csr, 7);
    ram.putWord(memmap.syst.csr + 0x20000, 7);
    cpu.banked.current = .non_secure;
    try cpu.reset(fixture.base);
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, cpu.run(1));
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(@as(usize, 0), cpu.active.depth);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.vtor));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.icsr + 0x20000));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.syst.csr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.syst.csr + 0x20000));
}

test "CPU foundation the first reset keeps the seeded SCS and every later reset clears it" {
    const fixture = @import("exception/ram.zig");
    const memmap = ra8.chip.core.memmap;
    const Cpu = ra8.chip.core.cpu.cpu.Cpu;
    const seeded = [_]u32{
        memmap.nvic.iser,           memmap.nvic.ipr,           memmap.scb.shcsr,
        memmap.scb.shpr3,           memmap.syst.rvr,           memmap.scb.shcsr + 0x20000,
        memmap.nvic.iser + 0x20000, memmap.syst.rvr + 0x20000,
    };
    var ram = fixture.Ram{};
    ram.putHalf(fixture.code, 0xBF00);
    for (seeded) |at| ram.putWord(at, 0x0007_0001);
    var cpu = try fixture.boot(&ram);
    // Power-on: the configuration seeded before the first reset is the boot's.
    try std.testing.expect(cpu.booted);
    for (seeded) |at| try std.testing.expectEqual(@as(u32, 0x0007_0001), ram.word(at));
    try std.testing.expectEqual(@as(u64, 0), cpu.slots);

    // A reboot before a single slot ran is still a reboot.
    try cpu.reset(fixture.base);
    for (seeded) |at| try std.testing.expectEqual(@as(u32, 0), ram.word(at));
    try std.testing.expectEqual(@as(u64, 0), cpu.slots);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);

    // And again with what a guest left behind after running.
    for (seeded) |at| ram.putWord(at, 0x0007_0001);
    try std.testing.expect(cpu.step() == null);
    try cpu.reset(fixture.base);
    for (seeded) |at| try std.testing.expectEqual(@as(u32, 0), ram.word(at));
    try std.testing.expectEqual(@as(u64, 1), cpu.slots);
    try std.testing.expectEqual(@as(u64, 1), cpu.retired);
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, cpu.run(1));
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 2), cpu.slots);

    // Power-on belongs to the core, not the bus: another core's first reset
    // on the same memory keeps what was seeded for it.
    for (seeded) |at| ram.putWord(at, 0x0007_0001);
    var other: Cpu = .{ .bus = ram.view() };
    try std.testing.expect(!other.booted);
    try other.reset(fixture.base);
    for (seeded) |at| try std.testing.expectEqual(@as(u32, 0x0007_0001), ram.word(at));
}

test "CPU foundation a failed first reset leaves the core unbooted" {
    var table: Table = .{ .words = &.{0x2200_2000} };
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = table.view() };
    try std.testing.expectError(bus.Error.Unmapped, cpu.reset(0));
    try std.testing.expect(!cpu.booted);
}
