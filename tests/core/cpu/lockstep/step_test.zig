//! Covers src/core/cpu/lockstep/step.zig.
const std = @import("std");
const ra8 = @import("ra8");
const step = ra8.core.cpu.lockstep.step;
const pair_mod = @import("pair.zig");
const Pair = pair_mod.Pair;

const IgnoreWrites = struct {
    inner: ra8.core.cpu.bus.Bus,

    fn view(self: *IgnoreWrites) ra8.core.cpu.bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) ra8.core.cpu.bus.Error!void {
        const self: *IgnoreWrites = @ptrCast(@alignCast(ctx));
        return self.inner.read(address, into);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) ra8.core.cpu.bus.Error!void {
        _ = ctx;
        _ = address;
        _ = bytes;
    }
};

test "a NOP on both backends matches under the hint class" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xBF, 0x00, 0xBF });
    defer pair.close();
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    try std.testing.expectEqualStrings("hint", result.matched);
    try std.testing.expectEqual(pair_mod.entry + 2, pair.cpu.regs.pc);
    try std.testing.expectEqualStrings("hint", (try step.one(&pair.cpu, pair.theirs, &pair.log, null)).matched);
}

test "a register the backends disagree on is reported with both values" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x00, 0xBF });
    defer pair.close();
    try pair.theirs.setRegister(.r0, 1);
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    const found = result.diverged;
    try std.testing.expectEqualStrings("hint", found.class);
    try std.testing.expectEqual(ra8.core.cpu.regs.Name.r0, found.what.register.name);
    try std.testing.expectEqual(@as(u32, 0), found.what.register.ours);
    try std.testing.expectEqual(@as(u32, 1), found.what.register.oracle);
}

test "an oracle-only store is reported as a memory divergence" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x0A, 0x60 }); // str r2, [r1]
    defer pair.close();
    var ignored: IgnoreWrites = .{ .inner = pair.cpu.bus };
    pair.cpu.bus = ignored.view();
    pair.cpu.regs.low[1] = pair_mod.entry + 0x100;
    pair.cpu.regs.low[2] = 0x1234;
    try ra8.core.cpu.lockstep.oracle.load(pair.theirs, ra8.core.cpu.lockstep.snapshot.Snapshot.fromRegs(&pair.cpu.regs));
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    const found = result.diverged;
    try std.testing.expect(found.what == .memory);
    try std.testing.expectEqual(pair_mod.entry + 0x100, found.what.memory.address);
    var buffer: [96]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try found.what.write(stream.writer());
    var want: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "memory at 0x{X:0>8}: zig 00000000, unicorn 34120000", .{pair_mod.entry + 0x100});
    try std.testing.expectEqualStrings(line, stream.getWritten());
}

test "an encoding the Zig core does not know stops both, unstepped" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x80, 0xBA }); // unallocated on Armv8-M
    defer pair.close();
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    try std.testing.expectEqual(@as(u16, 0xBA80), result.stopped.unknown.hw1);
    try std.testing.expectEqual(pair_mod.entry, try pair.theirs.register(.pc));
}

test "an IT and its one-instruction block match as one step" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x08, 0xBF, 0x01, 0x20, 0x00, 0xBF }); // it eq; moveq r0, #1; nop
    defer pair.close();
    pair.cpu.regs.xpsr |= 1 << 30; // Z
    try ra8.core.cpu.lockstep.oracle.load(pair.theirs, ra8.core.cpu.lockstep.snapshot.Snapshot.fromRegs(&pair.cpu.regs));
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    try std.testing.expectEqualStrings("it", result.matched);
    try std.testing.expectEqual(pair_mod.entry + 4, pair.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 1), pair.cpu.regs.low[0]);
}

test "an IT whose first instruction fails its condition still matches" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x08, 0xBF, 0x01, 0x20, 0x00, 0xBF }); // it eq, Z clear
    defer pair.close();
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    try std.testing.expectEqualStrings("it", result.matched);
    try std.testing.expectEqual(@as(u32, 0), pair.cpu.regs.low[0]);
}

test "an ITE and both instructions of its block match as one step" {
    var pair: Pair = undefined;
    try pair.open(&.{ 0x14, 0xBF, 0x01, 0x20, 0x02, 0x20, 0x00, 0xBF }); // ite ne; movne r0, #1; moveq r0, #2
    defer pair.close();
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    try std.testing.expectEqualStrings("it", result.matched);
    try std.testing.expectEqual(pair_mod.entry + 6, pair.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 1), pair.cpu.regs.low[0]);
}

test "the store that starts SysTick matches though Unicorn's hook stops on it" {
    // str r2, [r1]: r1 = SYST_CSR, r2 = ENABLE, with a reload already set
    var pair: Pair = undefined;
    try pair.open(&.{ 0x0A, 0x60 });
    defer pair.close();
    var clock: ra8.periph.clocks.Clocks = .{};
    try pair.theirs.attachTimebase(&clock);
    const memmap = ra8.core.memmap;
    try pair.theirs.write(memmap.syst.rvr, &.{ 0xFF, 0x00, 0x00, 0x00 });
    pair.cpu.regs.low[1] = memmap.syst.csr;
    pair.cpu.regs.low[2] = 1;
    try ra8.core.cpu.lockstep.oracle.load(pair.theirs, ra8.core.cpu.lockstep.snapshot.Snapshot.fromRegs(&pair.cpu.regs));
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, null);
    try std.testing.expectEqualStrings("ldst_imm", result.matched);
    try std.testing.expectEqual(pair_mod.entry + 2, pair.cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 1), clock.rearms);
}

test "a store of ones to CFSR clears the same bits on both sides within the step" {
    // str r2, [r1]: r1 = CFSR, r2 = DACCVIOL; IBUSERR stays raised
    var pair: Pair = undefined;
    try pair.open(&.{ 0x0A, 0x60 });
    defer pair.close();
    const memmap = ra8.core.memmap;
    const fault_clear = ra8.core.cpu.board_bus.fault_clear;
    var theirs_latch = fault_clear.Clears.init();
    try pair.theirs.attachFaultClears(&theirs_latch);
    var mine_latch = fault_clear.Clears.init();
    var replay: ra8.core.cpu.lockstep.replay_bus.ReplayBus = .{ .memory = pair.memory, .log = &pair.log, .scs = .{ .clears = &mine_latch } };
    pair.cpu.bus = replay.view();
    for ([_]ra8.core.engine.Engine{ pair.mine, pair.theirs }) |core| try core.write(memmap.scb.cfsr, &.{ 0x02, 0x01, 0x00, 0x00 });
    pair.cpu.regs.low[1] = memmap.scb.cfsr;
    pair.cpu.regs.low[2] = 0x2;
    try ra8.core.cpu.lockstep.oracle.load(pair.theirs, ra8.core.cpu.lockstep.snapshot.Snapshot.fromRegs(&pair.cpu.regs));
    const result = try step.one(&pair.cpu, pair.theirs, &pair.log, &theirs_latch);
    try std.testing.expectEqualStrings("ldst_imm", result.matched);
    try std.testing.expectEqual(@as(u32, 0x100), try pair.mine.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0x100), try pair.theirs.readWord(memmap.scb.cfsr));
}
