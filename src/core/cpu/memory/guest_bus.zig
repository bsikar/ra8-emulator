//! The Zig core's memory bus over a memory.Guest (RA8EMU-534): the core's
//! own store. The board bus and a bare run sit on this. The engine arm went
//! with RA8EMU-607.
const bus = @import("../bus.zig");
const MemoryBus = @import("memory_bus.zig").MemoryBus;
const Guest = @import("guest.zig").Guest;

pub const GuestBus = union(enum) {
    store: MemoryBus,

    /// The bus over `memory`. `fast` opens the direct MRAM/SRAM path.
    pub fn of(memory: *const Guest, fast: bool) GuestBus {
        return switch (memory.*) {
            .store => |held| .{ .store = .{ .store = held, .fast_enabled = fast } },
        };
    }

    pub fn view(self: *GuestBus) bus.Bus {
        return switch (self.*) {
            .store => |*memory| memory.view(),
        };
    }
};
