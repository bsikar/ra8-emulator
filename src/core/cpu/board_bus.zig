//! The Zig core's bus in a full run: the peripheral windows go to the
//! board's peripheral bus, the same handlers Unicorn's MMIO hooks call, and
//! everything else goes to memory through the engine.
//!
//! Both the Secure window and its Non-secure alias route to the one
//! peripheral bus, which folds the alias itself. A peripheral access is one
//! register access of 1, 2 or 4 bytes; any other width there is refused
//! rather than split, since splitting would change what the peripheral sees.
const std = @import("std");
const bus = @import("bus.zig");
const EngineBus = @import("engine_bus.zig").EngineBus;
const registry = @import("../../periph/registry.zig");
const memmap = @import("../memmap.zig");
const sau = @import("../../periph/sau.zig");

pub const BoardBus = struct {
    memory: EngineBus,
    periph: *registry.Bus,
    /// The core this bus view belongs to, stamped on every peripheral access.
    issuer: registry.Issuer = .cpu0,
    /// This core's SAU, when the board has one: its RBAR/RLAR bank through
    /// RNR on this bus exactly as src/core/sau_hook.zig banks them on Unicorn.
    partitions: ?*sau.Sau = null,

    pub fn view(self: *BoardBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    /// Whether the whole access sits in either peripheral window.
    pub fn inWindow(address: u32, len: usize) bool {
        const end = @as(u64, address) + len;
        for ([_]u32{ registry.base, registry.ns_base }) |window| {
            if (address >= window and end <= @as(u64, window) + registry.size) return true;
        }
        return false;
    }

    fn width(len: usize) bus.Error!u3 {
        return switch (len) {
            1, 2, 4 => @intCast(len),
            else => bus.Error.Unmapped,
        };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (!inWindow(address, into.len)) return self.memory.view().read(address, into);
        self.periph.issuer = self.issuer;
        const value = self.periph.read(address, try width(into.len));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        @memcpy(into, bytes[0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (!inWindow(address, bytes.len)) {
            try self.memory.view().write(address, bytes);
            if (self.partitions) |unit| try bankPartition(self.memory.view(), unit, address, bytes);
            return;
        }
        var padded = [_]u8{0} ** 4;
        const w = try width(bytes.len);
        @memcpy(padded[0..bytes.len], bytes);
        self.periph.issuer = self.issuer;
        self.periph.write(address, w, std.mem.readInt(u32, &padded, .little));
    }
};

/// File a word store into the SAU window and, when it moved RNR, put the
/// selected region's pair back in RAM so the next RBAR/RLAR read gives the
/// region RNR names rather than the last one programmed.
fn bankPartition(memory: bus.Bus, unit: *sau.Sau, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != 4 or address < memmap.sau.ctrl or address > memmap.sau.rlar) return;
    const word = std.mem.readInt(u32, bytes[0..4], .little);
    if (unit.observe(address, word) == .none) return;
    const pair = unit.bankedPair();
    for ([_][2]u32{ .{ memmap.sau.rbar, pair.rbar }, .{ memmap.sau.rlar, pair.rlar } }) |slot| {
        var word_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &word_bytes, slot[1], .little);
        try memory.write(slot[0], &word_bytes);
    }
}
