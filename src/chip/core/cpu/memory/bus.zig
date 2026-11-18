//! The Zig core's bus over its store, retaining the Guest initiator identity
//! and configuring the direct flash/SRAM fast path from the machine's
//! `MemoryMap` (RA8EMU-1343).
const bus = @import("../bus.zig");
const Initiator = @import("initiator.zig").Initiator;
const memory_map = @import("../../machine/memory.zig");
const Store = @import("store.zig").Store;

const Bound = struct {
    bytes: ?[]u8 = null,
    base: u32 = 0,
    size: u32 = 0,
    alias_base: ?u32 = null,
    writable: bool = false,
};

pub const MemoryBus = struct {
    store: *Store,
    initiator: Initiator = .none,
    fast_enabled: bool = false,
    direct: bus.DirectMemory = .{},

    pub fn view(self: *MemoryBus) bus.Bus {
        const flash = bindRole(self.store, .flash);
        const sram = bindRole(self.store, .sram);
        self.direct = .{
            .touched = self.store.touchesMut(),
            .flash = flash.bytes,
            .flash_base = flash.base,
            .flash_size = flash.size,
            .ns_flash_base = flash.alias_base,
            .flash_writable = flash.writable,
            .sram = sram.bytes,
            .sram_base = sram.base,
            .sram_size = sram.size,
            .ns_sram_base = sram.alias_base,
            .sram_writable = sram.writable,
            .enabled = self.fast_enabled,
            .checking = self.direct.checking,
            .observer = self.store.trail(),
            .initiator = self.initiator,
            .lines = self.store.fan(),
        };
        return .{
            .ctx = self,
            .vtable = &.{ .read = read, .write = write, .allowsExec = allowsExec },
            .direct = &self.direct,
            .lines = self.store.fanMut(),
        };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ctx));
        self.store.read(self.initiator, address, into) catch return bus.Error.Unmapped;
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ctx));
        self.store.write(self.initiator, address, bytes) catch return bus.Error.Unmapped;
    }

    fn allowsExec(ctx: *anyopaque, address: u32, len: usize) bool {
        const self: *MemoryBus = @ptrCast(@alignCast(ctx));
        return self.store.allowsExec(address, len);
    }
};

fn bindRole(store: *Store, role: memory_map.Role) Bound {
    const desc = store.map_desc;
    const region = desc.regionByRole(role) orelse return .{};
    if (!region.perms.read) return .{};
    return .{
        .bytes = store.mutRegion(region.base),
        .base = region.base,
        .size = region.size,
        .alias_base = fastAliasBase(desc, region),
        .writable = region.perms.write,
    };
}

fn fastAliasBase(desc: *const memory_map.MemoryMap, target: memory_map.Region) ?u32 {
    for (desc.aliases) |alias| {
        if (alias.of != target.base) continue;
        if (alias.size == target.size and alias.perms.read and alias.perms.write == target.perms.write) {
            return alias.view;
        }
    }
    return null;
}
