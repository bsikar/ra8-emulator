//! Memory, alias, MMIO, and security attribution map of a machine (RA8EMU-1343).
//!
//! Replaces hardcoded RA8D2/RA8P1 region, alias, and peripheral-window tables
//! across the store, direct fast path, block-cache line tracker, peripheral
//! bus, and ELF loader so each machine carries only the regions it actually
//! maps and faults at the first unmapped or disallowed byte.
const idau = @import("../../periph/idau.zig");
const memmap = @import("../memmap.zig");
const registry = @import("../../periph/registry.zig");

pub const Perms = memmap.Region.Perms;

pub const Role = enum {
    other,
    flash,
    sram,
    sdram,
    ppb,
};

/// Canonical backing region owned (or borrowed across cores when `shared`) by
/// a core's `Store`.
pub const Region = struct {
    name: []const u8,
    base: u32,
    size: u32,
    perms: Perms = .{},
    shared: bool = false,
    track_code: bool = false,
    role: Role = .other,

    pub fn end(self: Region) u64 {
        return @as(u64, self.base) + self.size;
    }

    pub fn covers(self: Region, address: u32, len: usize) bool {
        if (address < self.base) return false;
        return @as(u64, address) + len <= self.end();
    }
};

/// Alternate address view sharing the backing bytes of the canonical region at
/// `of` (for example a Secure/Non-secure alias).
pub const Alias = struct {
    name: []const u8,
    view: u32,
    of: u32,
    size: u32,
    perms: Perms = .{},

    pub fn end(self: Alias) u64 {
        return @as(u64, self.view) + self.size;
    }

    pub fn covers(self: Alias, address: u32, len: usize) bool {
        if (address < self.view) return false;
        return @as(u64, address) + len <= self.end();
    }
};

pub const ResolvedMmio = registry.ResolvedMmio;
pub const MmioWindow = registry.MmioWindow;
pub const UnknownMmio = registry.UnknownPolicy;
pub const PeripheralSet = enum { none, ra8_dual, ra8e1 };

/// Pluggable vendor IDAU attribution callback.
pub const IdauCallback = idau.Callback;

/// Maximum canonical regions and aliases one `Store` allocates.
pub const max_regions: usize = 16;
pub const max_aliases: usize = 16;

pub const MemoryMap = struct {
    regions: []const Region,
    aliases: []const Alias = &.{},
    mmio: []const MmioWindow = &.{},
    unknown_mmio: UnknownMmio = .shadow_alternating,
    attach_ra8_blocks: bool = false,
    peripheral_set: ?PeripheralSet = null,
    has_external: bool = false,
    allow_extra_pages: bool = false,
    idau: ?IdauCallback = null,

    pub fn resolvedPeripherals(self: *const MemoryMap) PeripheralSet {
        return self.peripheral_set orelse if (self.attach_ra8_blocks) .ra8_dual else .none;
    }

    pub fn indexOf(self: *const MemoryMap, base: u32) ?usize {
        for (self.regions, 0..) |entry, index| {
            if (entry.base == base) return index;
        }
        return null;
    }

    pub fn aliasIndexOf(self: *const MemoryMap, view_base: u32) ?usize {
        for (self.aliases, 0..) |entry, index| {
            if (entry.view == view_base) return index;
        }
        return null;
    }

    pub fn targetOf(self: *const MemoryMap, view_base: u32) ?u32 {
        for (self.aliases) |entry| {
            if (entry.view == view_base) return entry.of;
        }
        return null;
    }

    pub fn regionByRole(self: *const MemoryMap, role: Role) ?Region {
        for (self.regions) |entry| {
            if (entry.role == role) return entry;
        }
        return null;
    }

    pub fn aliasForTarget(self: *const MemoryMap, target_base: u32) ?Alias {
        for (self.aliases) |entry| {
            if (entry.of == target_base) return entry;
        }
        return null;
    }

    pub fn inMmio(self: *const MemoryMap, address: u32, len: usize) bool {
        for (self.mmio) |window| {
            if (window.covers(address, len)) return true;
        }
        return false;
    }

    pub fn touchesMmio(self: *const MemoryMap, address: u32, len: usize) bool {
        for (self.mmio) |window| {
            if (window.touches(address, len)) return true;
        }
        return false;
    }

    pub fn resolveMmio(self: *const MemoryMap, address: u32) ?ResolvedMmio {
        for (self.mmio) |window| {
            if (window.resolve(address)) |hit| return hit;
        }
        return null;
    }

    pub fn validStack(self: *const MemoryMap, sp: u32) bool {
        if (sp & 7 != 0) return false;
        for (self.regions) |entry| {
            if (entry.role == .ppb or !entry.perms.write) continue;
            if (sp > entry.base and @as(u64, sp) <= entry.end()) return true;
        }
        for (self.aliases) |entry| {
            if (!entry.perms.write) continue;
            if (sp > entry.view and @as(u64, sp) <= entry.end()) return true;
        }
        return false;
    }

    pub fn allowsExec(self: *const MemoryMap, address: u32, len: usize) ?bool {
        if (self.touchesMmio(address, len)) return false;
        for (self.regions) |entry| {
            if (entry.covers(address, len)) return entry.perms.exec;
        }
        for (self.aliases) |entry| {
            if (entry.covers(address, len)) return entry.perms.exec;
        }
        return null;
    }

    pub fn sdramBase(self: *const MemoryMap) u32 {
        return if (self.regionByRole(.sdram)) |entry| entry.base else memmap.sdram_base;
    }

    pub fn sramBase(self: *const MemoryMap) u32 {
        return if (self.regionByRole(.sram)) |entry| entry.base else memmap.sram_base;
    }

    pub fn overlapsFixed(self: *const MemoryMap, base: u32, size: u32) bool {
        const stop = @as(u64, base) + size;
        for (self.regions) |entry| {
            if (base < entry.end() and entry.base < stop) return true;
        }
        for (self.aliases) |alias| {
            if (base < alias.end() and alias.view < stop) return true;
        }
        return false;
    }
};

pub const ra8_regions = [_]Region{
    .{
        .name = "MRAM",
        .base = memmap.mram_base,
        .size = memmap.mram_end - memmap.mram_base,
        .track_code = true,
        .role = .flash,
    },
    .{
        .name = "DTCM",
        .base = memmap.dtcm_base,
        .size = memmap.dtcm_end - memmap.dtcm_base,
        .track_code = true,
    },
    .{
        .name = "SRAM",
        .base = memmap.sram_base,
        .size = memmap.sram_end - memmap.sram_base,
        .shared = true,
        .track_code = true,
        .role = .sram,
    },
    .{
        .name = "SDRAM",
        .base = memmap.sdram_base,
        .size = memmap.sdram_end - memmap.sdram_base,
        .shared = true,
        .role = .sdram,
    },
    .{
        .name = "PPB",
        .base = memmap.ppb_base,
        .size = memmap.ppb_size,
        .perms = .{ .exec = false },
        .role = .ppb,
    },
};

pub const ra8_aliases = [_]Alias{
    .{
        .name = "NS MRAM",
        .view = memmap.ns_mram_base,
        .of = memmap.mram_base,
        .size = memmap.ns_mram_end - memmap.ns_mram_base,
    },
    .{
        .name = "NS SRAM",
        .view = memmap.ns_sram_base,
        .of = memmap.sram_base,
        .size = memmap.ns_sram_end - memmap.ns_sram_base,
    },
    .{
        .name = "NS SDRAM",
        .view = memmap.ns_sdram_base,
        .of = memmap.sdram_base,
        .size = memmap.ns_sdram_end - memmap.ns_sdram_base,
    },
};

pub const ra8_mmio = [_]MmioWindow{
    .{ .base = registry.base, .size = registry.size, .ns_alias = registry.ns_base },
};

/// The default RA8D2/RA8P1 address map.
pub const ra8: MemoryMap = .{
    .regions = &ra8_regions,
    .aliases = &ra8_aliases,
    .mmio = &ra8_mmio,
    .unknown_mmio = .shadow_alternating,
    .attach_ra8_blocks = true,
    .has_external = true,
    .allow_extra_pages = true,
};
