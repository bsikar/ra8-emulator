//! CPU0's memory for a single-core `--cpu zig` run: the Zig core's own
//! store, with no Unicorn memory behind it (RA8EMU-580, slice 4d-2 of
//! RA8EMU-481).
//!
//! The board's blocks attach over the store, CPU0's PPB windows are primed
//! into it, and the image (and any `--ns` half) is loaded into it, in the
//! order the engine path does all three. The engine stays open beside it
//! for what still reads it: the reset line main announces, option memory
//! and the register dumps (RA8EMU-579).
//!
//! A run with a second core keeps the engine for now: CPU1 still steps over
//! engine memory, and the two cores have to share SRAM (RA8EMU-581). A
//! lockstep run compares against Unicorn, so it stays on the engine too.
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
    return options.cpu == .zig and options.cpu1_path == null;
}

pub const Cpu0 = struct {
    /// Null when the run stays on the engine.
    store: ?Store = null,

    /// Attach the board. A run that wants a store gets its blocks, its
    /// windows and the image there; any other run attaches to the engine
    /// exactly as before.
    pub fn attach(self: *Cpu0, board: *Board, core: *engine.Engine, image: elf.Image, options: cli.Options) !void {
        if (!wanted(options)) return board.attach(core);
        self.store = try Store.init(null);
        const memory = self.guest(core.*);
        try wiring.attachBlocks(board, memory);
        try wiring.primeWindows(board, memory, wiring.cpu0Windows(board));
        try self.load(image);
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
