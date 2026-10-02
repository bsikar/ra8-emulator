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
const mpu = @import("../../periph/mpu/mpu.zig");
/// Public so a test can build the latch without a root export.
pub const fault_clear = @import("../../periph/fault_clear.zig");

pub const BoardBus = struct {
    memory: EngineBus,
    periph: *registry.Bus,
    /// The core this bus view belongs to, stamped on every peripheral access.
    issuer: registry.Issuer = .cpu0,
    /// This core's SAU, when the board has one: its RBAR/RLAR bank through
    /// RNR on this bus exactly as src/core/sau_hook.zig banks them on Unicorn.
    partitions: ?*sau.Sau = null,
    /// This core's MPU table, banked through RNR the way src/core/mpu_hook.zig
    /// banks it on Unicorn. Enforcement is not armed from here.
    regions: ?*mpu.Mpu = null,
    /// CFSR, HFSR and SFSR are write-one-to-clear. Unicorn latches the clear
    /// in a hook and settles it at the boundary; here the store is settled
    /// as it lands, so no read in between sees the raw word.
    clears: ?*fault_clear.Clears = null,

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
        if (!inWindow(address, bytes.len)) return self.store(address, bytes);
        var padded = [_]u8{0} ** 4;
        const w = try width(bytes.len);
        @memcpy(padded[0..bytes.len], bytes);
        self.periph.issuer = self.issuer;
        self.periph.write(address, w, std.mem.readInt(u32, &padded, .little));
    }

    /// A store outside the peripheral windows: RAM, then whichever of the
    /// core's own SCS models the address belongs to.
    fn store(self: *BoardBus, address: u32, bytes: []const u8) bus.Error!void {
        const memory = self.memory.view();
        const owed = if (self.clears) |unit| (if (unit.slot(address) != null) unit else null) else null;
        const standing = if (owed != null) try memory.readWord(address & ~@as(u32, 3)) else 0;
        try memory.write(address, bytes);
        if (owed) |unit| {
            var padded = [_]u8{0} ** 4;
            @memcpy(padded[0..@min(bytes.len, 4)], bytes[0..@min(bytes.len, 4)]);
            unit.record(address, @intCast(bytes.len), std.mem.readInt(u32, &padded, .little), standing);
            unit.apply(self.memory.core.*) catch return bus.Error.Unmapped;
        }
        if (self.partitions) |unit| try bankPartition(memory, unit, address, bytes);
        if (self.regions) |unit| try bankRegion(memory, unit, address, bytes);
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
    try putWord(memory, memmap.sau.rbar, pair.rbar);
    try putWord(memory, memmap.sau.rlar, pair.rlar);
}

/// File a word store into the MPU window and, when it moved RNR, put the
/// four pairs RNR now selects back in RAM. A CTRL store is taken into the
/// table by `observe`; the Unicorn-only traps it rearms have no Zig twin.
fn bankRegion(memory: bus.Bus, unit: *mpu.Mpu, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != 4 or address < memmap.mpu.type_ or address > memmap.mpu.mair1) return;
    const word = std.mem.readInt(u32, bytes[0..4], .little);
    if (unit.observe(address, word) != .rebank) return;
    const pairs = [_][2]u32{
        .{ memmap.mpu.rbar, memmap.mpu.rlar },
        .{ memmap.mpu.rbar_a1, memmap.mpu.rlar_a1 },
        .{ memmap.mpu.rbar_a2, memmap.mpu.rlar_a2 },
        .{ memmap.mpu.rbar_a3, memmap.mpu.rlar_a3 },
    };
    for (pairs, 0..) |where, offset| {
        const words = unit.pairFor(@intCast(offset));
        try putWord(memory, where[0], words[0]);
        try putWord(memory, where[1], words[1]);
    }
}

fn putWord(memory: bus.Bus, address: u32, value: u32) bus.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try memory.write(address, &bytes);
}
