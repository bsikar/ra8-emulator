//! Covers src/board/wiring.zig: every part's board fits the peripheral
//! registry. An RA8P1 board once tipped over the block limit and every
//! `--device ra8p1` run stopped at TooManyBlocks (RA8EMU-94), so this attaches
//! a whole board per part and checks the bus still has room.
const std = @import("std");
const ra8 = @import("ra8");

const Engine = ra8.core.engine.Engine;
const Part = ra8.core.part.Part;
const max_blocks = ra8.periph.registry.max_blocks;
const Store = ra8.core.cpu.memory.store.Store;

/// The blocks a board of this part puts on the bus.
fn attachedBlocks(which: Part) !usize {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.part = which;
    try board.attach(&core);
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

/// The blocks alone, over the Zig core's store, with no engine open.
fn storeBlocks(which: Part) !usize {
    var store = try Store.init(null);
    defer store.deinit();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.part = which;
    try ra8.board.wiring.attachBlocks(&board, .{ .store = &store });
    return board.bus.count;
}

test "every part's blocks attach over a store, as many as an engine attach puts on" {
    for ([_]Part{ .ra8d2, .ra8p1 }) |which| {
        try std.testing.expectEqual(try attachedBlocks(which), try storeBlocks(which));
    }
}

test "CPU0's PPB windows are seeded into a store with no engine open" {
    var store = try Store.init(null);
    defer store.deinit();
    const memory: ra8.core.cpu.memory.guest.Guest = .{ .store = &store };
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try ra8.board.wiring.primeWindows(&board, memory, .{
        .partitions = &board.partitions,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .guard = &board.guard,
        .identity = ra8.periph.cpuid.cpu0,
        .control = &board.control,
        .clears = &board.clears,
    });
    const memmap = ra8.core.memmap;
    try std.testing.expectEqual(ra8.periph.cpuid.cpu0, try memory.readWord(ra8.periph.cpuid.address));
    try std.testing.expectEqual(ra8.periph.mpu.geometry.type_value, try memory.readWord(memmap.mpu.type_));
    try std.testing.expectEqual(ra8.periph.sau.geometry.type_value, try memory.readWord(memmap.sau.type_));
}
