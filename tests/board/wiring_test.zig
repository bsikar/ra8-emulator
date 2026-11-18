//! Covers src/board/wiring.zig: every part's board fits the peripheral
//! registry. An RA8P1 board once tipped over the block limit and every
//! `--device ra8p1` run stopped at TooManyBlocks (RA8EMU-94), so this attaches
//! a whole board per part and checks the bus still has room.
const std = @import("std");
const ra8 = @import("ra8");

const Part = ra8.chip.core.part.Part;
const max_blocks = ra8.chip.periph.registry.max_blocks;
const Store = ra8.chip.core.cpu.memory.store.Store;

/// The blocks a board of this part puts on the bus, over the Zig core's
/// store with no engine open: how a `--cpu zig` run attaches them.
fn attachedBlocks(which: Part) !usize {
    var store = try Store.init(null);
    defer store.deinit();
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.part = which;
    try ra8.board.wiring.attachBlocks(&board, .{ .store = &store });
    return board.bus.count;
}

test "an RA8P1 board attaches under the registry limit" {
    const count = try attachedBlocks(.ra8p1);
    try std.testing.expect(count > 0);
    try std.testing.expect(count < max_blocks);
}

test "an RA8D2 board attaches under the registry limit" {
    const count = try attachedBlocks(.ra8d2);
    try std.testing.expect(count > 0);
    try std.testing.expect(count < max_blocks);
}

test "CPU0's PPB windows are seeded into a store with no engine open" {
    var store = try Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try ra8.board.wiring.primeWindows(&board, memory, .{
        .partitions = &board.partitions,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .guard = &board.guard,
        .identity = ra8.chip.periph.cpuid.cpu0,
        .control = &board.control,
        .clears = &board.clears,
    });
    const memmap = ra8.chip.core.memmap;
    try std.testing.expectEqual(ra8.chip.periph.cpuid.cpu0, try memory.readWord(ra8.chip.periph.cpuid.address));
    try std.testing.expectEqual(ra8.chip.periph.mpu.geometry.type_value, try memory.readWord(memmap.mpu.type_));
    try std.testing.expectEqual(ra8.chip.periph.sau.geometry.type_value, try memory.readWord(memmap.sau.type_));
}

test "the run's panel_vsync config arms the clock after the display attaches" {
    var store = try Store.init(null);
    defer store.deinit();
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.panel_vsync = .{ .phase_ns = 4_000_000, .period_ns = 16_666_667 };
    try ra8.board.wiring.attachBlocks(&board, .{ .store = &store });
    if (board.display.output.vsync) |*clock| {
        try std.testing.expectEqual(@as(u64, 16_666_667), clock.period_ns);
        try std.testing.expectEqual(@as(u64, 4_000_000), clock.next_ns);
    } else return error.TestUnexpectedResult;
}

test "a board with no panel_vsync config leaves the clock unarmed" {
    var store = try Store.init(null);
    defer store.deinit();
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try ra8.board.wiring.attachBlocks(&board, .{ .store = &store });
    try std.testing.expect(board.display.output.vsync == null);
}

test "primeWindows seeds custom MPU, SAU, DWT, FPB, VTOR and SYST_CALIB capabilities" {
    var store = try Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try ra8.board.wiring.primeWindows(&board, memory, .{
        .partitions = &board.partitions,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .guard = &board.guard,
        .identity = ra8.chip.periph.cpuid.cpu1,
        .security = true,
        .systicks = 2,
        .scs = .{
            .sau_regions = 0,
            .mpu_regions_s = 12,
            .mpu_regions_ns = 4,
            .dwt_comparators = 2,
            .fpb_code = 6,
            .init_vtor = 0x0800_0000,
            .syst_calib = 0x4001_869F,
        },
        .control = &board.control,
        .clears = &board.clears,
    });
    const memmap = ra8.chip.core.memmap;
    try std.testing.expectEqual(@as(u32, 12 << 8), try memory.readWord(memmap.mpu.type_));
    try std.testing.expectEqual(@as(u32, 4 << 8), try memory.readWord(memmap.mpu.type_ + 0x20000));
    try std.testing.expectEqual(@as(u32, 0), try memory.readWord(memmap.sau.type_));
    try std.testing.expectEqual(@as(u32, 2 << 28), try memory.readWord(ra8.chip.periph.dwt.base));
    try std.testing.expectEqual(ra8.chip.periph.fpb.ctrlReset(6), try memory.readWord(ra8.chip.periph.fpb.base));
    try std.testing.expectEqual(@as(u32, 0x0800_0000), try memory.readWord(memmap.scb.vtor));
    try std.testing.expectEqual(@as(u32, 0x4001_869F), try memory.readWord(memmap.syst.calib));
    try std.testing.expectEqual(@as(u32, 0x4001_869F), try memory.readWord(memmap.syst.calib + 0x20000));
}

test "Board irq_override routes raise, tick repend, and reset latch clear on bare machine" {
    const machine_mod = ra8.chip.core.machine;
    const regions = [_]machine_mod.memory.Region{
        .{ .name = "FLASH", .base = 0x0000_0000, .size = 0x1_0000, .perms = .{ .write = false }, .role = .flash },
        .{ .name = "SRAM", .base = 0x2000_0000, .size = 0x1_0000, .role = .sram },
        .{ .name = "PPB", .base = 0xE000_0000, .size = 0x10_0000, .perms = .{ .exec = false }, .role = .ppb },
    };
    const bare_map: machine_mod.MemoryMap = .{ .regions = &regions, .attach_ra8_blocks = false };
    const bare_machine: machine_mod.Machine = .{
        .name = "bare-m33",
        .label = "Bare M33",
        .cores = .{ .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
            .scs = .{ .irq_lines = 40, .prio_bits = 3 },
        }) },
        .memory = &bare_map,
        .part = .ra8d2,
    };
    var store = try Store.initFor(null, &bare_map);
    defer store.deinit();
    const guest: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.machine = &bare_machine;
    try ra8.board.wiring.attachBlocks(&board, guest);

    var direct: ra8.chip.periph.irq_source.DirectLines = .{};
    direct.setLevelTriggered(12, true);
    board.irq_override[0] = direct.irqSource();
    var reboot: ra8.chip.core.reboot.Reboot = .{};
    board.reboot = &reboot;

    try board.raise(guest, 12);
    try std.testing.expect(board.irqSource(.cpu0).asserted(12));
    try std.testing.expectEqual(@as(u32, 1 << 12), try guest.readWord(ra8.chip.core.memmap.nvic.ispr));

    try guest.writeWord(ra8.chip.core.memmap.nvic.ispr, 0);
    try board.tick(guest, 10);
    try std.testing.expectEqual(@as(u64, 1), direct.repends);
    try std.testing.expectEqual(@as(u32, 1 << 12), try guest.readWord(ra8.chip.core.memmap.nvic.ispr));

    board.requestReset(.software);
    try std.testing.expect(!board.irqSource(.cpu0).asserted(12));
    try std.testing.expect(reboot.requested);
}
