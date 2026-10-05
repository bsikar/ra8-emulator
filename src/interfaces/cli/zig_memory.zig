//! CPU0's memory for a single-core `--cpu zig` run: the Zig core's own
//! store (RA8EMU-580, slice 4d-2 of
//! RA8EMU-481).
//!
//! The board's blocks attach over the store, CPU0's PPB windows are primed
//! into it, and the image (and any `--ns` half) is loaded into it, in the
//! order the engine path does all three. Since RA8EMU-592 a `--cpu zig` run
//! opens no engine at all: src/interfaces/cli/zig_main.zig attaches with
//! `attachStore` and reads everything back off the store.
//!
//! A run with a second core goes on the store too: CPU1 gets a store of its
//! own that borrows this one's shared SRAM (RA8EMU-588). Since RA8EMU-607
//! there is no engine arm left here: every run is on the store.
const elf = @import("../../core/elf.zig");
const Store = @import("../../core/cpu/memory/store.zig").Store;
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const loader = @import("../../core/cpu/memory/load.zig");
const wiring = @import("../../board/wiring.zig");
const Board = @import("../../board/board.zig").Board;
const cli = @import("cli.zig");

pub const Cpu0 = struct {
    /// Null until `attachStore` makes it.
    store: ?Store = null,

    /// Put CPU0 on a store of its own: the board's blocks, its windows, then
    /// the image. Returns the bytes the image wrote, for the opening line.
    pub fn attachStore(self: *Cpu0, board: *Board, image: elf.Image) !u32 {
        self.store = try Store.init(null);
        const memory = self.own();
        try wiring.attachBlocks(board, memory);
        try wiring.primeWindows(board, memory, wiring.cpu0Windows(board));
        return loader.image(memory, image);
    }

    /// The store, once `attachStore` has made it.
    pub fn own(self: *Cpu0) Guest {
        return .{ .store = &self.store.? };
    }

    /// Load a second image (the `--ns` half) into the store, if there is one.
    pub fn load(self: *Cpu0, image: elf.Image) !void {
        if (self.store) |*held| _ = try loader.image(.{ .store = held }, image);
    }

    pub fn close(self: *Cpu0) void {
        if (self.store) |*held| held.deinit();
        self.store = null;
    }
};
