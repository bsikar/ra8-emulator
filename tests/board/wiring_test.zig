//! Covers src/board/wiring.zig: every part's board fits the peripheral
//! registry. An RA8P1 board once tipped over the block limit and every
//! `--device ra8p1` run stopped at TooManyBlocks (RA8EMU-94), so this attaches
//! a whole board per part and checks the bus still has room.
const std = @import("std");
const ra8 = @import("ra8");

const Engine = ra8.core.engine.Engine;
const Part = ra8.core.part.Part;
const max_blocks = ra8.periph.registry.max_blocks;

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
