//! The Zig core's bus in lockstep: memory through its own engine, and the
//! peripheral windows answered from the log of what Unicorn just did there.
//!
//! A read in the window takes Unicorn's value for the same access; a write
//! is checked against Unicorn's and goes no further. Neither reaches a
//! peripheral, because Unicorn already did. When no instruction is being
//! replayed (a class Unicorn cannot check), a peripheral access is refused,
//! which stops the run as the bus fault it was before this existed.
const std = @import("std");
const bus = @import("../bus.zig");
const EngineBus = @import("../engine_bus.zig").EngineBus;
const board_bus = @import("../board_bus.zig");
const BoardBus = board_bus.BoardBus;
const periph_log = @import("periph_log.zig");

pub const ReplayBus = struct {
    memory: EngineBus,
    log: *periph_log.Log,
    /// The Zig side's own SAU, MPU and fault-clear latch, kept as the
    /// oracle's hooks keep its copy (mode.zig settles the oracle per step).
    scs: board_bus.Scs = .{},

    pub fn view(self: *ReplayBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn width(len: usize) bus.Error!u3 {
        return switch (len) {
            1, 2, 4 => @intCast(len),
            else => bus.Error.Unmapped,
        };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *ReplayBus = @ptrCast(@alignCast(ctx));
        if (!BoardBus.inWindow(address, into.len)) return self.memory.view().read(address, into);
        if (!self.log.armed) return bus.Error.Unmapped;
        // A mismatched read still completes, with zero, so the step can
        // report what differed instead of stopping on it.
        const value = self.log.takeRead(address, try width(into.len)) orelse 0;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        @memcpy(into, bytes[0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *ReplayBus = @ptrCast(@alignCast(ctx));
        if (!BoardBus.inWindow(address, bytes.len)) return self.scs.store(self.memory, address, bytes);
        if (!self.log.armed) return bus.Error.Unmapped;
        var padded = [_]u8{0} ** 4;
        const w = try width(bytes.len);
        @memcpy(padded[0..bytes.len], bytes);
        self.log.takeWrite(.{ .address = address, .width = w, .value = std.mem.readInt(u32, &padded, .little) });
    }
};
