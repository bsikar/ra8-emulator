//! CPU0's memory for a single-core `--cpu zig` run: the Zig core's own
//! store, with no Unicorn memory behind it (RA8EMU-580, slice 4d-2 of
//! RA8EMU-481).
//!
//! The board's blocks attach over the store, CPU0's PPB windows are primed
//! into it, and the image (and any `--ns` half) is loaded into it, in the
//! order the engine path does all three. Since RA8EMU-592 a `--cpu zig` run
//! opens no engine at all: src/interfaces/cli/zig_main.zig attaches with
//! `attachStore` and reads everything back off the store.
//!
//! A run with a second core goes on the store too: CPU1 gets a store of its
//! own that borrows this one's shared SRAM (RA8EMU-588). A lockstep run
//! compares against Unicorn, so it stays on the engine.
const engine = @import("../../core/engine.zig");
const elf = @import("../../core/elf.zig");
const Store = @import("../../core/cpu/memory/store.zig").Store;
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const loader = @import("../../core/cpu/memory/load.zig");
const wiring = @import("../../board/wiring.zig");
const Board = @import("../../board/board.zig").Board;
const cli = @import("cli.zig");

/// Whether this run's CPU0 runs on its own store.
pub fn wanted(options: cli.Options) bool {
    return options.cpu == .zig;
}

pub const Cpu0 = struct {
    /// Null when the run stays on the engine.
    store: ?Store = null,

    /// Attach the board. A run that wants a store gets its blocks, its
    /// windows and the image there; any other run attaches to the engine
    /// exactly as before.
    pub fn attach(self: *Cpu0, board: *Board, core: *engine.Engine, image: elf.Image, options: cli.Options) !void {
        if (!wanted(options)) return board.attach(core);
        _ = try self.attachStore(board, image);
    }

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

    /// CPU0's memory: the store when there is one, else the engine's.
    pub fn guest(self: *Cpu0, core: engine.Engine) Guest {
        if (self.store) |*held| return .{ .store = held };
        return .{ .engine = core };
    }

    pub fn close(self: *Cpu0) void {
        if (self.store) |*held| held.deinit();
        self.store = null;
    }
};
