//! The Zig core's bus over its own memory (RA8EMU-480): src/core/cpu/bus.zig
//! in front of src/core/cpu/memory/store.zig. It is the engine-free
//! counterpart of src/core/cpu/engine_bus.zig, with the same optional direct
//! path for code MRAM and system SRAM. An access that is not wholly inside
//! one memory region is refused as unmapped; the peripheral windows are the
//! board bus's (src/core/cpu/board_bus.zig), not this one's.
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const Store = @import("store.zig").Store;

pub const MemoryBus = struct {
    store: *const Store,
    /// Off by default for the same reason as EngineBus: a diagnostic that
    /// wraps the bus must see every access.
    fast_enabled: bool = false,
    direct: bus.DirectMemory = .{},

    pub fn view(self: *MemoryBus) bus.Bus {
        self.direct = .{
            .flash = self.store.region(memmap.mram_base),
            .sram = self.store.region(memmap.sram_base),
            .enabled = self.fast_enabled,
        };
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write }, .direct = &self.direct };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ctx));
        const bytes = self.store.span(address, into.len) orelse return bus.Error.Unmapped;
        @memcpy(into, bytes);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ctx));
        const into = self.store.span(address, bytes.len) orelse return bus.Error.Unmapped;
        @memcpy(into, bytes);
    }
};
