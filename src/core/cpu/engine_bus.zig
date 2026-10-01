//! The Zig core's memory, read and written through the Unicorn engine's own
//! mappings: the image as loaded, the board RAM and its aliases.
//!
//! This is how a `--cpu zig` run sees the same bytes Unicorn would, without a
//! second copy of the board. It goes straight to memory and so does not pass
//! through the peripheral hooks; a peripheral access from the Zig core waits
//! for the run loop to hand it the board's bus.
const bus = @import("bus.zig");
const engine = @import("../engine.zig");

pub const EngineBus = struct {
    core: *const engine.Engine,

    pub fn view(self: *EngineBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
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
