//! The Zig core's memory, read and written through the Unicorn engine's own
//! mappings: the image as loaded, the board RAM and its aliases.
//!
//! This is how a `--cpu zig` run sees the same bytes Unicorn would, without a
//! second copy of the board. It goes straight to memory and so does not pass
//! through the peripheral hooks; a peripheral access from the Zig core waits
//! for the run loop to hand it the board's bus.
const bus = @import("bus.zig");
const engine = @import("../engine.zig");
const memmap = @import("../memmap.zig");

pub const EngineBus = struct {
    core: *const engine.Engine,
    /// Opt-in keeps diagnostics able to insert their wrappers or injectors
    /// without a direct memory operation stepping around them.
    fast_enabled: bool = false,
    direct: bus.DirectMemory = .{},

    pub fn view(self: *EngineBus) bus.Bus {
        self.direct = .{
            .flash = self.core.ram.region(memmap.mram_base),
            .sram = self.core.ram.region(memmap.sram_base),
            .enabled = self.fast_enabled,
        };
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write }, .direct = &self.direct };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *EngineBus = @ptrCast(@alignCast(ctx));
        self.core.read(address, into) catch return bus.Error.Unmapped;
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *EngineBus = @ptrCast(@alignCast(ctx));
        self.core.write(address, bytes) catch return bus.Error.Unmapped;
    }
};
