//! Covers src/chip/core/cpu/cpu.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

test {
    _ = @import("attribution_test.zig");
    _ = @import("data_gate_test.zig");
    _ = @import("tt_mpu_test.zig");
    _ = @import("park_test.zig");
    _ = @import("fetch_guard_test.zig");
    _ = @import("fixed_trip_test.zig");
    _ = @import("trip_decode_test.zig");
    _ = @import("counted/bound_test.zig");
    _ = @import("counted/trip_test.zig");
    _ = @import("systick_cut_test.zig");
    _ = @import("bti_test.zig");
    _ = @import("scs_route_test.zig");
    _ = @import("mpu_check_test.zig");
}

/// A little image at address 0: a vector table, then code at 0x08.
const Image = struct {
    bytes: []const u8,

    fn view(self: *Image) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Image = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

// sp 0x20001000, reset 0x09 ; bf00 nop ; f3af 8000 nop.w ; ba80 (unallocated)
const boots_to_udf = [_]u8{
    0x00, 0x10, 0x00, 0x20, 0x09, 0x00, 0x00, 0x00,
    0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x80, 0xBA,
};

test "a run goes through the nops and stops on the first unknown encoding" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    try cpu.reset(0);
    const stopped = cpu.run(100);
    try std.testing.expectEqual(@as(u32, 0x0E), stopped.unknown.address);
    try std.testing.expectEqual(@as(u16, 0xBA80), stopped.unknown.hw1);
    try std.testing.expectEqual(@as(u32, 0x0E), cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 2), cpu.retired);
}

test "a run stops after the count it was given" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    try cpu.reset(0);
    try std.testing.expectEqual(.count, std.meta.activeTag(cpu.run(1)));
    try std.testing.expectEqual(@as(u32, 0x0A), cpu.regs.pc);
}

test "a clear T bit stops before the fetch" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    try cpu.reset(0);
    cpu.regs.xpsr = 0;
    try std.testing.expectEqual(@as(u32, 0x08), cpu.run(1).invalid_state);
}

test "running off the end of memory is a bus fault on the fetch" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    cpu.regs.xpsr = regs.xpsr_bits.thumb;
    cpu.regs.pc = 0x10;
    try std.testing.expectEqual(@as(u32, 0x10), cpu.run(1).bus_fault);
}

fn programWord(ram: ra8.chip.core.cpu.memory.guest.Guest, address: u32, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try ram.program(address, &buf);
}

fn programHalf(ram: ra8.chip.core.cpu.memory.guest.Guest, address: u32, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try ram.program(address, &buf);
}

test "Cortex-M55 core executes Armv8.1-M/PAC hints, reads M55 IDs, and faults PACG" {
    const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
    const Guest = ra8.chip.core.cpu.memory.guest.Guest;
    const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
    const Store = ra8.chip.core.cpu.memory.store.Store;
    const core_mod = ra8.chip.core.machine.core;
    const cpuid = ra8.chip.periph.cpuid;
    const id_regs = ra8.chip.periph.id_regs;
    const memmap = ra8.chip.core.memmap;
    const registry = ra8.chip.periph.registry;

    const m55 = core_mod.cortexM55(.{ .security = true, .fpu = .double, .systicks = 2 });
    var store = try Store.init(null);
    defer store.deinit();
    const ram: Guest = .{ .store = &store };
    try cpuid.prime(ram.asInitiator(.none), m55.cpuid);
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{
        .memory = GuestBus.of(&ram, false),
        .periph = &periph,
        .scs = .{
            .config = m55.scs,
            .systicks = m55.systicks,
            .has_security = m55.security,
            .dwt_numcomp = m55.dwtComparators(),
            .fpb_wired = true,
            .id = m55.idBank(),
        },
    };
    const base = memmap.mram_base;
    try programWord(ram, base + 0x00, memmap.sram_base + 0x1000);
    try programWord(ram, base + 0x04, base + 0x81);
    try programWord(ram, base + 0x18, base + 0x101); // UsageFault handler
    try board.view().writeWord(0xE000_EDF0, 1); // DHCSR.C_DEBUGEN so BKPT halts
    try board.view().writeWord(memmap.scb.shcsr, 1 << 18); // USGFAULTENA
    // base+0x80: pac, pacbti, aut, bti, csel r1, r0, r2, eq, pacg r2, r1, r3 (UsageFault)
    const code = [_]u16{
        0xF3AF, 0x801D, 0xF3AF, 0x800D, 0xF3AF, 0x802D, 0xF3AF, 0x800F,
        0xEA50, 0x8102, 0xFB61, 0xF203,
    };
    for (code, 0..) |hw, i| try programHalf(ram, base + 0x80 + @as(u32, @intCast(i * 2)), hw);
    try programHalf(ram, base + 0x100, 0xBE00); // BKPT in UsageFault

    var cpu: Cpu = .{ .bus = board.view(), .profile = m55.profile };
    try cpu.reset(base);
    cpu.regs.set(0, 10);
    cpu.regs.set(1, 20);
    cpu.regs.set(2, 30);
    cpu.regs.set(12, 0x5555_6666);
    _ = cpu.run(6); // pac..bti NOPs, csel, then pacg -> UsageFault -> BKPT
    try std.testing.expectEqual(@as(u32, 0x5555_6666), cpu.regs.get(12));
    try std.testing.expectEqual(@as(u32, 30), cpu.regs.get(1)); // EQ was false so r1 = r2 (CSEL)
    try std.testing.expectEqual(base + 0x100, cpu.regs.pc);
    try std.testing.expect(try board.view().readWord(memmap.scb.cfsr) & (1 << 16) != 0);
    try std.testing.expectEqual(@as(u32, 0x411F_D221), try board.view().readWord(cpuid.address));
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(id_regs.addr.id_isar5));
    try std.testing.expectEqual(@as(u32, 0x1011_0221), try board.view().readWord(id_regs.addr.mvfr0));
    try std.testing.expectEqual(@as(u32, 0x1210_0211), try board.view().readWord(id_regs.addr.mvfr1));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), try board.view().readWord(memmap.dwt.ctrl));

    // Soft reset clears CONTROL and preserves architectural M55 ID registers.
    try cpu.reset(base);
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(id_regs.addr.id_isar5));
    try std.testing.expectEqual(@as(u32, 0x411F_D221), try board.view().readWord(cpuid.address));
}

test "Cortex-M55 runs LOB and MVE integer while checking FPB/DWT/PRIO config" {
    const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
    const Guest = ra8.chip.core.cpu.memory.guest.Guest;
    const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
    const Store = ra8.chip.core.cpu.memory.store.Store;
    const core_mod = ra8.chip.core.machine.core;
    const dwt = ra8.chip.periph.dwt;
    const fpb = ra8.chip.periph.fpb;
    const memmap = ra8.chip.core.memmap;
    const registry = ra8.chip.periph.registry;

    const hx_core = core_mod.cortexM55(.{
        .security = true,
        .fpu = .single,
        .fp16 = true,
        .mve = true,
        .mve_fp = true,
        .lob = true,
        .systicks = 2,
        .scs = .{ .prio_bits = 3, .dwt_comparators = 4, .fpb_code = 8 },
    });
    var store = try Store.init(null);
    defer store.deinit();
    const ram: Guest = .{ .store = &store };
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{
        .memory = GuestBus.of(&ram, false),
        .periph = &periph,
        .scs = .{
            .config = hx_core.scs,
            .systicks = hx_core.systicks,
            .has_security = hx_core.security,
            .dwt_numcomp = hx_core.dwtComparators(),
            .fpb_wired = true,
            .id = hx_core.idBank(),
        },
    };
    const base = memmap.mram_base;
    try programWord(ram, base + 0x00, memmap.sram_base + 0x1000);
    try programWord(ram, base + 0x04, base + 0x81);
    try board.view().writeWord(0xE000_EDF0, 1); // DHCSR.C_DEBUGEN
    // base+0x80: dls lr, r0 (0xF040 0xE001); 0x84: adds r1, #1 (0x3101);
    // base+0x86: le lr, base+0x84 (0xF00F 0xC803 -> end=0x8A, -6=0x84);
    // base+0x8A: vadd.i32 q0, q1, q2 (0xEF22 0x0844); 0x8E: bkpt (0xBE00)
    const code = [_]u16{ 0xF040, 0xE001, 0x3101, 0xF00F, 0xC803, 0xEF22, 0x0844, 0xBE00 };
    for (code, 0..) |hw, i| try programHalf(ram, base + 0x80 + @as(u32, @intCast(i * 2)), hw);

    var cpu: Cpu = .{ .bus = board.view(), .profile = hx_core.profile };
    try cpu.reset(base);
    cpu.fp.cpacr = 0x00F0_0000;
    cpu.regs.set(0, 3);
    cpu.regs.set(1, 0);
    cpu.fp.bank.writeS(4, 10);
    cpu.fp.bank.writeS(8, 32);
    try std.testing.expectEqual(.breakpoint, std.meta.activeTag(cpu.run(12)));
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.get(1));
    try std.testing.expectEqual(@as(u32, 42), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(fpb.ctrlReset(hx_core.scs.fpb_code), try board.view().readWord(fpb.base));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), try board.view().readWord(dwt.base));
    try std.testing.expectEqual(@as(u32, 0x1011_0021), try board.view().readWord(ra8.chip.periph.id_regs.addr.mvfr0));
}
