//! CPU0's memory for a `--cpu zig` run: the Zig core's own store backed by
//! the machine description's `MemoryMap` (RA8EMU-580, RA8EMU-1343).
const backing = @import("external/backing.zig");
const Board = @import("board.zig").Board;
const elf = @import("image/elf.zig");
const external = @import("external/memory.zig");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const loader = @import("ra8_chip").core.cpu.memory.load;
const read_image = @import("image/load.zig");
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const wiring = @import("wiring.zig");

pub const Cpu0 = struct {
    /// Null until `attachStore` makes it.
    store: ?Store = null,
    /// The board's SDRAM and fabric behind the store's external port.
    external: ?backing.Backing = null,

    /// Put CPU0 on a store of its own: the board's blocks, its windows, then
    /// the image. Returns the bytes the image wrote, for the opening line.
    pub fn attachStore(self: *Cpu0, board: *Board, image: elf.Image) !u32 {
        const mem_desc = board.desc().memory;
        self.store = try Store.initFor(null, mem_desc);
        if (mem_desc.has_external) {
            const layout = try external.Layout.init(board.external_memory);
            self.external = try backing.Backing.init(layout, board.nor.window());
            self.store.?.attachExternal(self.external.?.port());
        }
        const memory = self.own();
        try wiring.attachBlocks(board, memory);
        try wiring.primeWindows(board, memory, wiring.cpu0Windows(board));
        const loaded = try read_image.readFor(image, mem_desc);
        return loader.image(memory, loaded.image());
    }

    /// The store, once `attachStore` has made it.
    pub fn own(self: *Cpu0) Guest {
        return .{ .store = &self.store.? };
    }

    /// Load a second image (the `--ns` half) into the store, if there is one.
    pub fn load(self: *Cpu0, image: elf.Image) !void {
        const held = &(self.store orelse return);
        const loaded = try read_image.readFor(image, held.map_desc);
        _ = try loader.image(.{ .store = held }, loaded.image());
    }

    pub fn close(self: *Cpu0) void {
        if (self.store) |*held| held.deinit();
        self.store = null;
        if (self.external) |*held| held.deinit();
        self.external = null;
    }
};
