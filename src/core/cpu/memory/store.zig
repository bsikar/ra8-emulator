//! The Zig core's host-backed memory store, including profile-selected
//! external SDRAM and the board-owned mapped OSPI array.
const std = @import("std");
const memmap = @import("../../memmap.zig");
const external = @import("../../external_memory.zig");
const Initiator = @import("initiator.zig").Initiator;
const nor = @import("../../../periph/xspi/xspi_flash.zig");
const extra = @import("extra.zig");

pub const Error = error{OutOfMemory};
pub const AccessError = error{Unmapped} || Error;
pub const MapError = extra.Error;

pub const Store = struct {
    pages: [memmap.ram.len]?[]u8 = @splat(null),
    owned: [memmap.ram.len]bool = @splat(false),
    extra: extra.Extra = .{},
    layout: ?external.Layout = null,
    flash: ?*nor.Flash = null,
    fabric: ?*external.Fabric = null,
    owns_external: bool = false,

    /// Back every fixed region. A second core borrows shared SRAM/SDRAM and
    /// the same external fabric, while retaining private MRAM, TCM and PPB.
    pub fn init(lender: ?*const Store) Error!Store {
        var self: Store = .{};
        errdefer self.deinit();
        for (memmap.ram, 0..) |entry, index| {
            if (viewOf(entry.base) != null) continue;
            if (lender) |first| if (shared(entry.base)) {
                self.pages[index] = first.pages[index];
                continue;
            };
            self.pages[index] = try allocate(entry.size);
            self.owned[index] = true;
        }
        for (memmap.ram, 0..) |entry, index| {
            const secure = viewOf(entry.base) orelse continue;
            self.pages[index] = self.pages[indexOf(secure).?];
        }
        if (lender) |first| {
            self.layout = first.layout;
            self.flash = first.flash;
            self.fabric = first.fabric;
        }
        return self;
    }

    pub fn configureExternal(self: *Store, layout: external.Layout, flash: *nor.Flash) Error!void {
        flash.resize(layout.size(.ospi)) catch return Error.OutOfMemory;
        const bytes = try allocate(layout.size(.sdram));
        errdefer std.heap.page_allocator.free(bytes);
        const secure_index = indexOf(memmap.sdram_base).?;
        if (self.owned[secure_index]) if (self.pages[secure_index]) |old| std.heap.page_allocator.free(old);
        self.pages[secure_index] = bytes;
        self.owned[secure_index] = false;
        self.pages[indexOf(memmap.ns_sdram_base).?] = bytes;
        const fabric = std.heap.page_allocator.create(external.Fabric) catch return Error.OutOfMemory;
        fabric.* = external.Fabric.init(layout);
        self.layout = layout;
        self.flash = flash;
        self.fabric = fabric;
        self.owns_external = true;
    }

    pub fn deinit(self: *Store) void {
        if (self.owns_external) {
            if (self.pages[indexOf(memmap.sdram_base).?]) |bytes| std.heap.page_allocator.free(bytes);
            if (self.fabric) |fabric| std.heap.page_allocator.destroy(fabric);
            self.pages[indexOf(memmap.sdram_base).?] = null;
            self.pages[indexOf(memmap.ns_sdram_base).?] = null;
        }
        for (&self.pages, &self.owned) |*held, *mine| {
            if (mine.*) if (held.*) |bytes| std.heap.page_allocator.free(bytes);
            held.* = null;
            mine.* = false;
        }
        self.extra.deinit();
        self.layout = null;
        self.flash = null;
        self.fabric = null;
        self.owns_external = false;
    }

    /// Zero every region this store owns and drop the windows it mapped,
    /// so a live store reads as a fresh one before a snapshot fills it
    /// (RA8EMU-768). Borrowed regions are the lender's to clear.
    pub fn wipe(self: *Store) void {
        for (self.pages, self.owned) |held, mine| {
            if (mine) if (held) |bytes| @memset(bytes, 0);
        }
        if (self.owns_external) if (self.region(memmap.sdram_base)) |bytes| @memset(bytes, 0);
        self.extra.deinit();
    }

    pub fn region(self: *const Store, base: u32) ?[]u8 {
        return self.pages[indexOf(base) orelse return null];
    }

    /// A directly addressable host span. Mapped OSPI stays behind read/write
    /// so its erased inversion and NOR program semantics cannot be bypassed.
    pub fn span(self: *const Store, address: u32, len: usize) ?[]u8 {
        if (self.layout) |layout| if (layout.locate(address, len)) |hit| {
            if (hit.kind == .sdram) return self.pages[indexOf(memmap.sdram_base).?].?[hit.offset..][0..len];
            return null;
        };
        if (self.layout) |layout| if (layout.overlaps(address, len)) return null;
        for (memmap.ram, 0..) |entry, index| {
            if (address < entry.base or address >= entry.end()) continue;
            const offset = address - entry.base;
            const bytes = self.pages[index] orelse return null;
            if (offset > bytes.len or len > bytes.len - offset) return null;
            return bytes[offset..][0..len];
        }
        return self.extra.span(address, len);
    }

    pub fn read(self: *Store, initiator: Initiator, address: u32, into: []u8) AccessError!void {
        if (into.len == 0) return;
        if (self.layout) |layout| if (layout.locate(address, into.len)) |hit| {
            switch (hit.kind) {
                .ospi => if (!self.flash.?.readMapped(hit.offset, into)) return AccessError.Unmapped,
                .sdram => @memcpy(into, self.pages[indexOf(memmap.sdram_base).?].?[hit.offset..][0..into.len]),
            }
            self.fabric.?.note(initiator, hit, .read, into.len);
            return;
        };
        @memcpy(into, self.span(address, into.len) orelse return AccessError.Unmapped);
    }

    pub fn write(self: *Store, initiator: Initiator, address: u32, bytes: []const u8) AccessError!void {
        if (bytes.len == 0) return;
        if (self.layout) |layout| if (layout.locate(address, bytes.len)) |hit| {
            switch (hit.kind) {
                .ospi => if (!(try self.flash.?.writeMapped(hit.offset, bytes))) return AccessError.Unmapped,
                .sdram => @memcpy(self.pages[indexOf(memmap.sdram_base).?].?[hit.offset..][0..bytes.len], bytes),
            }
            self.fabric.?.note(initiator, hit, .write, bytes.len);
            return;
        };
        @memcpy(self.span(address, bytes.len) orelse return AccessError.Unmapped, bytes);
    }

    pub fn backed(self: *const Store, address: u32, len: usize) bool {
        if (self.layout) |layout| if (layout.locate(address, len) != null) return true;
        return self.span(address, len) != null;
    }

    pub fn map(self: *Store, base: u32, size: u32) MapError!void {
        if (self.span(base, 1) != null) return MapError.Mapped;
        if (external.supportedOverlap(base, size)) return MapError.Mapped;
        return self.extra.map(base, size);
    }
};

fn viewOf(base: u32) ?u32 {
    if (base == memmap.ns_mram_base) return memmap.mram_base;
    for (memmap.alias_of) |pair| if (pair.view == base) return pair.of;
    return null;
}

fn shared(base: u32) bool {
    for (memmap.alias_of) |pair| if (pair.of == base) return true;
    return false;
}

fn indexOf(base: u32) ?usize {
    for (memmap.ram, 0..) |entry, index| if (entry.base == base) return index;
    return null;
}

fn allocate(size: u32) Error![]u8 {
    const bytes = std.heap.page_allocator.alloc(u8, size) catch return Error.OutOfMemory;
    @memset(bytes, 0);
    return bytes;
}
