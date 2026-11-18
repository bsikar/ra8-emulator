//! The Zig core's host-backed memory store. Region ownership, aliases, and
//! permissions come from the machine's `MemoryMap` (RA8EMU-1343); off-chip
//! SDRAM and OSPI sit behind the external port when attached (RA8EMU-1041).
const touched_api = @import("touched.zig");

const std = @import("std");

const code_lines = @import("../code_lines.zig");
const external_port = @import("external_port.zig");
const extra = @import("extra.zig");
const Initiator = @import("initiator.zig").Initiator;
const memory_map = @import("../../machine/memory.zig");
const observer = @import("observer.zig");

pub const Error = error{OutOfMemory};
pub const AccessError = error{Unmapped} || Error;
pub const MapError = extra.Error;
pub const Located = struct { base: u32, offset: usize, bytes: []const u8 };
pub const LocatedMut = struct { base: u32, offset: usize, bytes: []u8 };
pub const SdramSet = std.StaticBitSet(128 * 1024 * 1024 / 4096);

pub const Store = struct {
    map_desc: *const memory_map.MemoryMap = &memory_map.ra8,
    touched: touched_api.Tracker = .{},
    sdram_resident: SdramSet = .empty,
    sdram_demand_zero: bool = false,
    pages: [memory_map.max_regions]?[]u8 = @splat(null),
    alias_pages: [memory_map.max_aliases]?[]u8 = @splat(null),
    owned: [memory_map.max_regions]bool = @splat(false),
    extra: extra.Extra = .{},
    port: ?external_port.Port = null,
    owns_port: bool = false,
    observer: ?*const observer.Observer = null,
    fanout: code_lines.Fanout = .{},
    lender: ?*Store = null,

    pub fn init(lender: ?*Store) Error!Store {
        return initFor(lender, if (lender) |first| first.map_desc else &memory_map.ra8);
    }

    pub fn initFor(lender: ?*Store, desc: *const memory_map.MemoryMap) Error!Store {
        var self: Store = .{
            .map_desc = desc,
            .touched = .{ .sram_base = desc.sramBase(), .sdram_base = desc.sdramBase() },
            .fanout = .{ .layout = code_lines.Layout.fromMap(desc) },
        };
        errdefer self.deinit();
        const count = @min(desc.regions.len, memory_map.max_regions);
        for (desc.regions[0..count], 0..) |entry, index| {
            if (lender) |first| if (entry.shared) {
                self.pages[index] = first.pages[index];
                continue;
            };
            self.pages[index] = try allocate(entry.size);
            self.owned[index] = true;
        }
        if (lender) |first| {
            self.port = first.port;
            self.sdram_demand_zero = first.sdram_demand_zero;
        }
        self.lender = lender;
        self.syncAliases();
        return self;
    }

    pub fn attachExternal(self: *Store, port: external_port.Port) void {
        if (self.sdramIndex()) |idx| {
            if (self.owned[idx]) if (self.pages[idx]) |old| std.heap.PageAllocator.unmap(@alignCast(old));
            self.pages[idx] = port.sdram;
            self.owned[idx] = false;
        }
        self.syncAliases();
        self.port = port;
        self.owns_port = true;
        self.sdram_demand_zero = port.demand_zero;
        self.sdram_resident = .empty;
        self.barrier(.attach_external);
    }

    fn syncAliases(self: *Store) void {
        const count = @min(self.map_desc.aliases.len, memory_map.max_aliases);
        for (self.map_desc.aliases[0..count], 0..) |alias, idx| {
            self.alias_pages[idx] = if (self.map_desc.indexOf(alias.of)) |target| self.pages[target] else null;
        }
    }

    pub fn deinit(self: *Store) void {
        if (self.owns_port) if (self.sdramIndex()) |idx| {
            self.pages[idx] = null;
        };
        for (&self.pages, &self.owned) |*held, *mine| {
            if (mine.*) if (held.*) |bytes| std.heap.PageAllocator.unmap(@alignCast(bytes));
            held.* = null;
            mine.* = false;
        }
        @memset(&self.alias_pages, null);
        self.extra.deinit();
        self.port = null;
        self.owns_port = false;
        self.observer = null;
        self.lender = null;
    }

    pub fn wipe(self: *Store) void {
        if (self.owns_port) self.wipeSdram();
        self.touched = .{ .sram_base = self.map_desc.sramBase(), .sdram_base = self.map_desc.sdramBase() };
        self.barrier(.wipe);
        for (self.pages, self.owned) |held, mine| {
            if (mine) if (held) |bytes| @memset(bytes, 0);
        }
        self.extra.deinit();
        self.notifyCodeRanges();
    }

    fn wipeSdram(self: *Store) void {
        const sdram = self.port.?.sdram;
        if (self.sdram_demand_zero and sdram.len <= 128 * 1024 * 1024) {
            var it = self.sdram_resident.iterator(.{});
            while (it.next()) |page| {
                const off = page * 4096;
                if (off < sdram.len) @memset(sdram[off..@min(off + 4096, sdram.len)], 0);
            }
            self.sdram_resident = .empty;
        } else @memset(sdram, 0);
    }

    pub fn sdramResident(self: *const Store) *const SdramSet {
        return if (self.lender) |first| first.sdramResident() else &self.sdram_resident;
    }

    pub fn noteSdramResident(self: *Store, offset: usize, len: usize) void {
        if (len == 0) return;
        if (self.lender) |first| return first.noteSdramResident(offset, len);
        const end = @min((offset + len - 1) / 4096 + 1, self.sdram_resident.capacity());
        var page = offset / 4096;
        while (page < end) : (page += 1) {
            self.sdram_resident.set(page);
        }
    }

    pub fn touches(self: *const Store) *const touched_api.Tracker {
        return if (self.lender) |first| first.touches() else &self.touched;
    }

    pub fn touchesMut(self: *Store) *touched_api.Tracker {
        return if (self.lender) |first| first.touchesMut() else &self.touched;
    }

    pub fn region(self: *const Store, base: u32) ?[]const u8 {
        return self.pages[self.canonicalIndex(base) orelse return null];
    }

    pub fn span(self: *const Store, address: u32, len: usize) ?[]const u8 {
        return (self.locate(address, len) orelse return null).bytes;
    }

    pub fn locate(self: *const Store, address: u32, len: usize) ?Located {
        if (self.port) |*port| {
            if (port.geometry.locate(address, len)) |hit| {
                if (hit.kind == .sdram) return .{
                    .base = self.sdramBase(),
                    .offset = hit.offset,
                    .bytes = port.sdram[hit.offset..][0..len],
                };
                return null;
            }
            if (port.geometry.overlaps(address, len)) return null;
        }
        if (self.locateFixedRead(address, len)) |hit| return hit;
        const hit = self.extra.locate(address, len) orelse return null;
        return .{ .base = hit.base, .offset = hit.offset, .bytes = hit.bytes };
    }

    fn locateFixedRead(self: *const Store, address: u32, len: usize) ?Located {
        const count = @min(self.map_desc.regions.len, memory_map.max_regions);
        for (self.map_desc.regions[0..count], 0..) |entry, idx| {
            if (!entry.covers(address, len)) continue;
            if (!entry.perms.read) return null;
            const bytes = self.pages[idx] orelse return null;
            const offset = address - entry.base;
            const span_bytes = sliceAt(bytes, offset, len) orelse return null;
            return .{ .base = entry.base, .offset = offset, .bytes = span_bytes };
        }
        const alias_count = @min(self.map_desc.aliases.len, memory_map.max_aliases);
        for (self.map_desc.aliases[0..alias_count], 0..) |alias, idx| {
            if (!alias.covers(address, len)) continue;
            if (!alias.perms.read) return null;
            const bytes = self.alias_pages[idx] orelse return null;
            const offset = address - alias.view;
            const span_bytes = sliceAt(bytes, offset, len) orelse return null;
            return .{ .base = alias.of, .offset = offset, .bytes = span_bytes };
        }
        return null;
    }

    pub fn locateMut(self: *Store, address: u32, len: usize) ?LocatedMut {
        return self.locateWritable(address, len, false);
    }

    fn locateWritable(self: *Store, address: u32, len: usize, check_perm: bool) ?LocatedMut {
        if (self.port) |*port| {
            if (port.geometry.locate(address, len)) |hit| {
                if (hit.kind == .sdram) return .{
                    .base = self.sdramBase(),
                    .offset = hit.offset,
                    .bytes = port.sdram[hit.offset..][0..len],
                };
                return null;
            }
            if (port.geometry.overlaps(address, len)) return null;
        }
        if (self.locateFixedMut(address, len, check_perm)) |hit| return hit;
        const hit = self.extra.locateMut(address, len) orelse return null;
        return .{ .base = hit.base, .offset = hit.offset, .bytes = hit.bytes };
    }

    fn locateFixedMut(self: *Store, address: u32, len: usize, check_perm: bool) ?LocatedMut {
        const count = @min(self.map_desc.regions.len, memory_map.max_regions);
        for (self.map_desc.regions[0..count], 0..) |entry, idx| {
            if (!entry.covers(address, len)) continue;
            if (check_perm and !entry.perms.write) return null;
            const bytes = self.pages[idx] orelse return null;
            const offset = address - entry.base;
            const span_bytes = sliceAtMut(bytes, offset, len) orelse return null;
            return .{ .base = entry.base, .offset = offset, .bytes = span_bytes };
        }
        const alias_count = @min(self.map_desc.aliases.len, memory_map.max_aliases);
        for (self.map_desc.aliases[0..alias_count], 0..) |alias, idx| {
            if (!alias.covers(address, len)) continue;
            if (check_perm and !alias.perms.write) return null;
            const bytes = self.alias_pages[idx] orelse return null;
            const offset = address - alias.view;
            const span_bytes = sliceAtMut(bytes, offset, len) orelse return null;
            return .{ .base = alias.of, .offset = offset, .bytes = span_bytes };
        }
        return null;
    }

    pub fn read(self: *Store, initiator: Initiator, address: u32, into: []u8) AccessError!void {
        if (into.len == 0) return;
        if (self.port) |*port| if (port.geometry.locate(address, into.len)) |hit| {
            switch (hit.kind) {
                .ospi => if (!port.flash.read(hit.offset, into)) return AccessError.Unmapped,
                .sdram => @memcpy(into, port.sdram[hit.offset..][0..into.len]),
            }
            port.meter.note(initiator, hit, .read, into.len);
            return;
        };
        @memcpy(into, self.span(address, into.len) orelse return AccessError.Unmapped);
    }

    pub fn write(self: *Store, initiator: Initiator, address: u32, bytes: []const u8) AccessError!void {
        return self.writeMode(initiator, address, bytes, true);
    }

    pub fn program(self: *Store, initiator: Initiator, address: u32, bytes: []const u8) AccessError!void {
        return self.writeMode(initiator, address, bytes, false);
    }

    fn writeMode(
        self: *Store,
        initiator: Initiator,
        address: u32,
        bytes: []const u8,
        check_perm: bool,
    ) AccessError!void {
        if (bytes.len == 0) return;
        if (self.port) |*port| if (port.geometry.locate(address, bytes.len)) |hit| {
            return self.writeExternal(port, initiator, hit, bytes);
        };
        const target = self.locateWritable(address, bytes.len, check_perm) orelse return AccessError.Unmapped;
        self.hookBytes(initiator, target.base, target.offset, target.bytes, bytes);
        @memcpy(target.bytes, bytes);
    }

    fn writeExternal(
        self: *Store,
        port: *external_port.Port,
        initiator: Initiator,
        hit: external_port.Hit,
        bytes: []const u8,
    ) AccessError!void {
        switch (hit.kind) {
            .ospi => if (!(try port.flash.write(hit.offset, bytes))) return AccessError.Unmapped,
            .sdram => {
                const dest = port.sdram[hit.offset..][0..bytes.len];
                self.hookBytes(initiator, self.sdramBase(), hit.offset, dest, bytes);
                @memcpy(dest, bytes);
            },
        }
        port.meter.note(initiator, hit, .write, bytes.len);
    }

    pub fn rawWrite(self: *Store, address: u32, bytes: []const u8) AccessError!void {
        if (bytes.len == 0) return;
        self.touchesMut().invalidate();
        if (self.port) |*port| if (port.geometry.locate(address, bytes.len)) |hit| {
            switch (hit.kind) {
                .ospi => port.flash.rawWrite(hit.offset, bytes),
                .sdram => {
                    self.noteSdramResident(hit.offset, bytes.len);
                    @memcpy(port.sdram[hit.offset..][0..bytes.len], bytes);
                },
            }
            return;
        };
        const target = self.locateMut(address, bytes.len) orelse return AccessError.Unmapped;
        @memcpy(target.bytes, bytes);
        self.notifyCodeRanges();
    }

    pub fn barrier(self: *Store, event: observer.Barrier) void {
        if (event == .snapshot_load) self.touchesMut().invalidate();
        if (self.trail()) |o| o.barrier(event);
    }

    pub fn backed(self: *const Store, address: u32, len: usize) bool {
        if (self.port) |*port| if (port.geometry.locate(address, len) != null) return true;
        return self.span(address, len) != null;
    }

    pub fn allowsExec(self: *const Store, address: u32, len: usize) bool {
        return self.map_desc.allowsExec(address, len) orelse self.backed(address, len);
    }

    pub fn map(self: *Store, base: u32, size: u32) MapError!void {
        if (self.map_desc.overlapsFixed(base, size) or self.span(base, 1) != null) return MapError.Mapped;
        if (self.map_desc.has_external and external_port.supportedOverlap(base, size)) return MapError.Mapped;
        try self.extra.map(base, size);
        self.barrier(.{ .mapped = .{ .base = base, .size = size } });
    }

    pub fn fan(self: *const Store) *const code_lines.Fanout {
        return if (self.lender) |first| first.fan() else &self.fanout;
    }

    pub fn fanMut(self: *Store) *code_lines.Fanout {
        return if (self.lender) |first| first.fanMut() else &self.fanout;
    }

    pub fn trail(self: *const Store) ?*const observer.Observer {
        return if (self.lender) |first| first.trail() else self.observer;
    }

    pub fn notifyCodeRanges(self: *const Store) void {
        const count = @min(self.map_desc.regions.len, memory_map.max_regions);
        for (self.map_desc.regions[0..count], self.owned[0..count]) |entry, mine| {
            if (mine and entry.track_code) self.fan().notify(entry.base, entry.size);
        }
    }

    pub fn mutRegion(self: *Store, base: u32) ?[]u8 {
        return self.pages[self.canonicalIndex(base) orelse return null];
    }

    fn canonicalIndex(self: *const Store, base: u32) ?usize {
        return self.map_desc.indexOf(self.map_desc.targetOf(base) orelse base);
    }

    fn sdramIndex(self: *const Store) ?usize {
        return self.map_desc.indexOf((self.map_desc.regionByRole(.sdram) orelse return null).base);
    }

    pub fn sdramBase(self: *const Store) u32 {
        return self.map_desc.sdramBase();
    }

    inline fn hookBytes(
        self: *Store,
        initiator: Initiator,
        base: u32,
        offset: usize,
        pre: []const u8,
        new: []const u8,
    ) void {
        if (base == self.sdramBase()) self.noteSdramResident(offset, new.len);
        self.touchesMut().note(base, offset, new.len);
        if (self.trail()) |o| {
            o.bytes(.{ .base = base, .offset = offset, .initiator = initiator, .pre = pre, .new = new });
        }
    }
};

fn allocate(size: u32) Error![]u8 {
    const align_min: std.mem.Alignment = .fromByteUnits(std.heap.page_size_min);
    const ptr = std.heap.PageAllocator.map(size, align_min) orelse return Error.OutOfMemory;
    return ptr[0..size];
}

fn sliceAt(bytes: []const u8, offset: usize, len: usize) ?[]const u8 {
    if (offset > bytes.len or len > bytes.len - offset) return null;
    return bytes[offset..][0..len];
}

fn sliceAtMut(bytes: []u8, offset: usize, len: usize) ?[]u8 {
    if (offset > bytes.len or len > bytes.len - offset) return null;
    return bytes[offset..][0..len];
}
