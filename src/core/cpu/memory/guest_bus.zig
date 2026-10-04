//! The Zig core's memory bus over a memory.Guest (RA8EMU-534): the engine's
//! mappings while Unicorn still holds the board, or the core's own store.
//! The board bus and a bare run sit on this, so neither cares which backend
//! holds the bytes; the engine arm goes with the engine (RA8EMU-482).
const bus = @import("../bus.zig");
const EngineBus = @import("../engine_bus.zig").EngineBus;
const MemoryBus = @import("memory_bus.zig").MemoryBus;
const Guest = @import("guest.zig").Guest;

pub const GuestBus = union(enum) {
    engine: EngineBus,
    store: MemoryBus,

    /// The bus over `memory`. `fast` opens the direct MRAM/SRAM path; the
    /// engine arm keeps a pointer into `memory`, so it must outlive the bus.
    pub fn of(memory: *const Guest, fast: bool) GuestBus {
        return switch (memory.*) {
            .engine => |*core| .{ .engine = .{ .core = core, .fast_enabled = fast } },
            .store => |held| .{ .store = .{ .store = held, .fast_enabled = fast } },
        };
    }

    pub fn view(self: *GuestBus) bus.Bus {
        return switch (self.*) {
            .engine => |*memory| memory.view(),
            .store => |*memory| memory.view(),
        };
    }
};
