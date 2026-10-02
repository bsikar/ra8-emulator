//! Tests for src/core/second_core.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.second_core;
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const Engine = engine.Engine;
const Board = ra8.board.Board;
const sau = ra8.periph.sau;
const mpu = ra8.periph.mpu;
const scb = ra8.periph.scb;
const nvic = ra8.periph.nvic;

/// A thumb image is not needed to test the wiring: what matters is that the
/// second core is put in front of the first core's board and takes turns.
///
/// CPU1 is built into storage the caller holds, the way `open` requires:
/// its watch is registered with Unicorn by address, so a `Second` moved
/// after that leaves the hook pointing at where it used to be.
fn pair(cpu1: *mod.Second) !Engine {
    var cpu0 = try Engine.open();
    errdefer cpu0.close();
    try cpu0.mapBoardRam();
    cpu1.* = .{ .core = try Engine.open() };
    errdefer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    try cpu1.core.attachWatch(&cpu1.watch);
    try cpu1.core.attachPend(&cpu1.pend);
    return cpu0;
}

test "what one core stores in shared SRAM the other core reads" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    try cpu1.core.writeWord(memmap.ns_sram_base + 0x100200, 0xB055_A55A);
    try std.testing.expectEqual(
        @as(u32, 0xB055_A55A),
        try cpu0.readWord(memmap.sram_base + 0x100200),
    );
}

test "no path named means no second core, and the storage is left alone" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var storage = mod.Second{ .core = undefined, .turns = 7 };
    const none = try mod.start(std.testing.allocator, &cpu0, &board, null, &storage);
    try std.testing.expect(none == null);
    try std.testing.expectEqual(@as(usize, 7), storage.turns);
}

test "a second core carries an SAU of its own, not the board's" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(&cpu1.partitions != &board.partitions);
}

test "a fresh second core's SAU is quiet, so it prints no line" {
    var cpu1 = mod.Second{ .core = undefined };
    try std.testing.expect(cpu1.partitions.quiet());
}

test "one core's SAU map does not land in the other's table" {
    var mine = sau.Sau.init();
    var theirs = sau.Sau.init();

    // CPU0 programmes region 0 as Non-Secure Callable.
    _ = mine.observe(memmap.sau.rnr, 0);
    _ = mine.observe(memmap.sau.rbar, 0x0200_0000);
    _ = mine.observe(memmap.sau.rlar, 0x0207_FFE0 | sau.field.rlar_enable | sau.field.rlar_nsc);
    // CPU1 programmes its own region 0 as plain Non-Secure.
    _ = theirs.observe(memmap.sau.rnr, 0);
    _ = theirs.observe(memmap.sau.rbar, 0x5000_0000);
    _ = theirs.observe(memmap.sau.rlar, 0x5FFF_FFE0 | sau.field.rlar_enable);

    try std.testing.expectEqual(@as(u8, 1), mine.callable());
    try std.testing.expectEqual(@as(u8, 0), theirs.callable());
    try std.testing.expectEqual(@as(u32, 0x0200_0000), mine.table[0].base);
    try std.testing.expectEqual(@as(u32, 0x5000_0000), theirs.table[0].base);
}

test "a round is the chunk boundary" {
    try std.testing.expectEqual(ra8.core.cadence.instructions, mod.limits.round);
}

test "a second core carries an MPU and guard of its own, not the board's" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    cpu1.regions = mpu.Mpu.init();
    cpu1.guard = ra8.core.mpu_guard.Guard.init();

    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(&cpu1.regions != &board.regions);
    try std.testing.expect(&cpu1.guard != &board.guard);

    // The guard CPU1 attaches enforces CPU1's table, never the board's.
    try cpu1.core.attachRegions(&cpu1.regions, &cpu1.guard);
    try std.testing.expect(cpu1.guard.unit.? == &cpu1.regions);
    try std.testing.expect(board.guard.unit == null);
}

test "programming one core's MPU leaves the other's table alone" {
    var cpu0_regions = mpu.Mpu.init();
    const cpu1_regions = mpu.Mpu.init();

    // CPU0 programmes region 2 over the first SRAM page and enables.
    _ = cpu0_regions.observe(memmap.mpu.rnr, 2);
    _ = cpu0_regions.observe(memmap.mpu.rbar, memmap.sram_base);
    _ = cpu0_regions.observe(memmap.mpu.rlar, (memmap.sram_base + 0xFE0) | 1);
    _ = cpu0_regions.observe(memmap.mpu.ctrl, mpu.field.ctrl_enable);

    try std.testing.expectEqual(memmap.sram_base, cpu0_regions.table[2].base);
    try std.testing.expectEqual(@as(u8, 2), cpu0_regions.selected);
    try std.testing.expectEqual(@as(u32, 0), cpu1_regions.table[2].base);
    try std.testing.expectEqual(@as(u8, 0), cpu1_regions.selected);
    try std.testing.expectEqual(@as(u32, 0), cpu1_regions.ctrl);
}

test "a fresh second core's MPU is empty and off" {
    const cpu1 = mod.Second{ .core = undefined };
    try std.testing.expectEqual(@as(u32, 0), cpu1.regions.ctrl);
    try std.testing.expect(cpu1.guard.unit == null);
}

test "each core reads its own VTOR, primed to its own vector base" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    const base: u32 = memmap.sram_base + 0x0010_0000;

    try mod.primeVectorTable(cpu1.core, base);
    try std.testing.expectEqual(base, try cpu1.core.readWord(memmap.scb.vtor));
    try std.testing.expectEqual(@as(u32, 0), try cpu0.readWord(memmap.scb.vtor));
}

test "moving CPU0's vector table leaves CPU1's VTOR where it was" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    const base: u32 = memmap.sram_base + 0x0010_0000;
    try mod.primeVectorTable(cpu1.core, base);

    try cpu0.writeWord(memmap.scb.vtor, memmap.sram_base);
    try std.testing.expectEqual(memmap.sram_base, try cpu0.readWord(memmap.scb.vtor));
    try std.testing.expectEqual(base, try cpu1.core.readWord(memmap.scb.vtor));
}

test "each core's AIRCR model keeps the PRIGROUP that core programmed" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    cpu1.control = scb.Scb.init();
    var cpu0_control = scb.Scb.init();
    try cpu0_control.prime(cpu0);
    try cpu1.control.prime(cpu1.core);

    const keyed: u32 = scb.key.write << scb.key.shift;
    try cpu1.core.writeWord(memmap.scb.aircr, keyed | (5 << 8));
    try std.testing.expect(!try cpu1.control.poll(cpu1.core));
    try std.testing.expect(!try cpu0_control.poll(cpu0));

    try std.testing.expectEqual(@as(u3, 5), cpu1.control.priorityGroup());
    try std.testing.expectEqual(@as(u3, 0), cpu0_control.priorityGroup());
    try std.testing.expectEqual(scb.key.status, try cpu0.readWord(memmap.scb.aircr));
}

test "a reset CPU1 asks for is counted on CPU1's model, not CPU0's" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    cpu1.control = scb.Scb.init();
    const cpu0_control = scb.Scb.init();
    try cpu1.control.prime(cpu1.core);

    const keyed: u32 = scb.key.write << scb.key.shift;
    try cpu1.core.writeWord(memmap.scb.aircr, keyed | scb.field.sysresetreq);
    try std.testing.expect(try cpu1.control.poll(cpu1.core));
    try std.testing.expectEqual(@as(u32, 1), cpu1.control.requests);
    try std.testing.expectEqual(@as(u32, 0), cpu0_control.requests);
}

test "CCR, SHCSR and the fault status words are each core's own" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    const words = [_]u32{ memmap.scb.ccr, 0xE000_ED24, 0xE000_ED28, 0xE000_ED2C, 0xE000_ED34, 0xE000_ED38 };
    for (words, 0..) |address, i| {
        try cpu0.writeWord(address, 0x100 + @as(u32, @intCast(i)));
        try std.testing.expectEqual(@as(u32, 0), try cpu1.core.readWord(address));
    }
}

/// CPU1 parked in a `b .` spin over a vector table whose PendSV entry is a
/// second spin, so where it ends up says whether the exception was taken.
const Spins = struct {
    const table: u32 = memmap.sram_base + 0x1000;
    const spin: u32 = table + 0x100;
    const handler: u32 = table + 0x200;
    const stack: u32 = memmap.sram_base + 0x8000;

    fn lay(core: Engine) !void {
        try core.writeWord(table, stack);
        try core.writeWord(table + 4, spin | 1);
        try core.writeWord(table + 4 * nvic.pendsv, handler | 1);
        try core.writeWord(table + 4 * nvic.systick, handler | 1);
        try core.writeWord(spin, 0xE7FE_E7FE);
        try core.writeWord(handler, 0xE7FE_E7FE);
    }

    fn boot(cpu1: *mod.Second) !void {
        try lay(cpu1.core);
        cpu1.interrupts = .{ .vector_base = table };
        try mod.primeVectorTable(cpu1.core, table);
        try cpu1.core.resetFromVectorTable(table);
        cpu1.pc = try cpu1.core.register(.pc);
    }
};

test "a PendSV pended on CPU1 is taken by CPU1's own NVIC" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try Spins.boot(&cpu1);

    try cpu1.core.writeWord(memmap.scb.icsr, nvic.icsr_pendsvset);
    cpu1.step(1000);
    try std.testing.expect(cpu1.fault == null);
    try std.testing.expectEqual(@as(u64, 1), cpu1.interrupts.taken);
    try std.testing.expectEqual(Spins.handler, cpu1.pc & ~@as(u32, 1));

    // CPU0 saw none of it: nothing is pended in its own ICSR.
    var cpu0_interrupts = nvic.Nvic{ .vector_base = Spins.table };
    try std.testing.expect(try cpu0_interrupts.dispatch(cpu0) == null);
}

test "a PendSV CPU1's own code stores ends CPU1's stretch" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try Spins.boot(&cpu1);
    // ldr r0, =ICSR; ldr r1, =PENDSVSET; str r1, [r0]; b .
    try cpu1.core.writeWord(Spins.spin, 0x4902_4801);
    try cpu1.core.writeWord(Spins.spin + 4, 0xE7FE_6001);
    try cpu1.core.writeWord(Spins.spin + 8, memmap.scb.icsr);
    try cpu1.core.writeWord(Spins.spin + 12, nvic.icsr_pendsvset);

    cpu1.step(1000);
    try std.testing.expect(cpu1.fault == null);
    // The store cut the stretch, so PendSV landed where the architecture
    // puts it rather than at the end of the turn.
    try std.testing.expectEqual(@as(usize, 1), cpu1.pend.cuts);
    try std.testing.expectEqual(@as(u64, 1), cpu1.interrupts.taken);
    try std.testing.expectEqual(Spins.handler, cpu1.pc & ~@as(u32, 1));
}

test "a PendSV pended on CPU0 is never taken by CPU1" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try Spins.boot(&cpu1);

    try cpu0.writeWord(memmap.scb.icsr, nvic.icsr_pendsvset);
    cpu1.step(1000);
    try std.testing.expect(cpu1.fault == null);
    try std.testing.expectEqual(@as(u64, 0), cpu1.interrupts.taken);
    try std.testing.expectEqual(Spins.spin, cpu1.pc & ~@as(u32, 1));
}

test "CPU1's SysTick counts on CPU1 and pends into CPU1's own NVIC" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try Spins.boot(&cpu1);

    try cpu1.core.writeWord(memmap.syst.rvr, 99);
    try cpu1.core.writeWord(memmap.syst.cvr, 0);
    try cpu1.core.writeWord(memmap.syst.csr, 0b111);
    cpu1.step(1000);
    try std.testing.expect(cpu1.fault == null);
    try std.testing.expect(cpu1.timebase.ticks > 0);
    try std.testing.expect(cpu1.interrupts.taken >= 1);
    try std.testing.expectEqual(Spins.handler, cpu1.pc & ~@as(u32, 1));

    // CPU0's SysTick was never armed and nothing was pended on it.
    try std.testing.expectEqual(@as(u32, 0), try cpu0.readWord(memmap.syst.csr));
    try std.testing.expectEqual(@as(u32, 0), try cpu0.readWord(memmap.scb.icsr) & nvic.icsr_pendstset);
}

test "CPU0's SysTick never ticks CPU1's time base" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try Spins.boot(&cpu1);

    try cpu0.writeWord(memmap.syst.rvr, 99);
    try cpu0.writeWord(memmap.syst.csr, 0b111);
    cpu1.step(1000);
    try std.testing.expectEqual(@as(u64, 0), cpu1.timebase.ticks);
    try std.testing.expectEqual(@as(u64, 0), cpu1.interrupts.taken);
    try std.testing.expectEqual(@as(u32, 0), try cpu1.core.readWord(memmap.syst.csr));
}

/// Through a real file, because the SAU half of the report writes to a
/// file writer rather than any writer.
fn reported(second: *const mod.Second, buffer: []u8) ![]const u8 {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile("report.txt", .{ .read = true });
    defer file.close();
    try mod.report(file.writer(), second);
    try file.seekTo(0);
    return buffer[0..try file.readAll(buffer)];
}

test "the report says how often CPU1 parked in WFE and what woke it" {
    var second: mod.Second = .{ .core = undefined };
    second.wait.parks = 3;
    second.wait.wakes = .{ .interrupt = 1, .event = 1, .spurious = 1 };
    var buffer: [1024]u8 = undefined;
    const text = try reported(&second, &buffer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "CPU1: parked in WFE 3 time(s), woken 1 by an exception, 1 by SEV, 1 spuriously\n",
    ) != null);
}

test "a CPU1 that never waited reports no parking line" {
    const second: mod.Second = .{ .core = undefined };
    var buffer: [1024]u8 = undefined;
    const text = try reported(&second, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "parked in WFE") == null);
}

/// A masked spin three instructions wide, entered at its `cpsie i`, so a
/// turn of a multiple of three meets every boundary with PRIMASK set: the
/// shape of the module port's `__tx_ts_wait` against CPU1's turn.
const MaskedSpin = struct {
    const loop: u32 = Spins.table + 0x300;

    fn boot(cpu1: *mod.Second) !void {
        try Spins.lay(cpu1.core);
        // cpsid i; cpsie i; b loop
        try cpu1.core.writeWord(loop, 0xB662_B672);
        try cpu1.core.writeWord(loop + 4, 0xE7FE_E7FC);
        try cpu1.core.writeWord(Spins.table + 4, (loop + 2) | 1);
        cpu1.interrupts = .{ .vector_base = Spins.table };
        try mod.primeVectorTable(cpu1.core, Spins.table);
        try cpu1.core.resetFromVectorTable(Spins.table);
        cpu1.pc = try cpu1.core.register(.pc);
    }
};

test "a SysTick held by CPU1's mask is taken when the mask clears" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try MaskedSpin.boot(&cpu1);

    try cpu1.core.writeWord(memmap.scb.icsr, nvic.icsr_pendstset);
    cpu1.step(999);
    try std.testing.expect(cpu1.fault == null);
    try std.testing.expect(cpu1.release.lifted >= 1);
    try std.testing.expectEqual(@as(u64, 1), cpu1.interrupts.taken);
    try std.testing.expectEqual(Spins.handler, cpu1.pc & ~@as(u32, 1));
}
