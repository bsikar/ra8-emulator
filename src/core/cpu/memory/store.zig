//! The Zig core's own memory: every region of src/core/memmap.zig on host
//! pages, with no Unicorn engine behind it (RA8EMU-480). It is the first
//! slice of RA8EMU-255; until a run is moved onto it, the Zig core still
//! reads through the engine (src/core/cpu/engine_bus.zig).
//!
//! It keeps the rules src/core/board_ram.zig keeps for the engine.
//!
//! A NON-SECURE VIEW IS THE SAME BYTES. Each pair in `memmap.alias_of`, and
//! code MRAM with its bit-28 view, is one allocation answering at two
//! addresses, so a store through one view is read back through the other.
//!
//! THE PAGES ARE ZEROED HERE. Reset state is a silicon fact, and a host
//! allocator that recycles would otherwise hand a second store the first
//! one's bytes.
//!
//! THE SHARED SRAM IS LENT, NOT COPIED. A second core's store borrows the
//! `alias_of` pairs (system SRAM and SDRAM) from the first core's, so CPU1
//! sees CPU0's stores the instant they land. Code MRAM, the TCMs and the PPB
//! stay per core: CPU1 can load its own image, and each core has its own
//! SCS. A borrower must not outlive the store it borrowed from.
const std = @import("std");
const memmap = @import("../../memmap.zig");
const extra = @import("extra.zig");

pub const Error = error{OutOfMemory};
pub const MapError = extra.Error;

pub const Store = struct {
    /// Host bytes for each `memmap.ram` entry, in the same order. A view
    /// holds the same slice as the region it is a view of.
    pages: [memmap.ram.len]?[]u8 = @splat(null),
    /// Which entries this store allocated, and so frees.
    owned: [memmap.ram.len]bool = @splat(false),
    /// Windows outside memmap, mapped by peripherals at attach (extra.zig).
    /// Per core: a borrower never sees its lender's.
    extra: extra.Extra = .{},

    /// Back every region. With a `lender`, the shared regions are the
    /// lender's pages rather than fresh ones.
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
        // Every view sits 0x1000_0000 above the region it views, so each
        // one's pages exist by now.
        for (memmap.ram, 0..) |entry, index| {
            const secure = viewOf(entry.base) orelse continue;
            self.pages[index] = self.pages[indexOf(secure).?];
        }
        return self;
    }

    /// Release what this store allocated. Borrowed pages stay with their
    /// owner, and a view's pages go with the region it views.
    pub fn deinit(self: *Store) void {
        for (&self.pages, &self.owned) |*held, *mine| {
            if (mine.*) if (held.*) |bytes| std.heap.page_allocator.free(bytes);
            held.* = null;
            mine.* = false;
        }
        self.extra.deinit();
    }

    /// Host bytes for the whole region based at `base`, either view.
    pub fn region(self: *const Store, base: u32) ?[]u8 {
        return self.pages[indexOf(base) orelse return null];
    }

    /// Host bytes for `len` bytes at `address`, or null when they are not
    /// all inside one region.
    pub fn span(self: *const Store, address: u32, len: usize) ?[]u8 {
        for (memmap.ram, 0..) |entry, index| {
            if (address < entry.base or address >= entry.end()) continue;
            const offset = address - entry.base;
            if (len > entry.size - offset) return null;
            const bytes = self.pages[index] orelse return null;
            return bytes[offset..][0..len];
        }
        return self.extra.span(address, len);
    }

    /// Back a window outside memmap. A range inside a memmap region, or one
    /// touching a window already mapped, fails with Mapped.
    pub fn map(self: *Store, base: u32, size: u32) MapError!void {
        if (self.span(base, 1) != null) return MapError.Mapped;
        return self.extra.map(base, size);
    }
};

/// The base of the region `base` is the Non-secure view of, or null when it
/// is not a view.
fn viewOf(base: u32) ?u32 {
    if (base == memmap.ns_mram_base) return memmap.mram_base;
    for (memmap.alias_of) |pair| {
        if (pair.view == base) return pair.of;
    }
    return null;
}

/// Whether a second core shares this region with the first.
fn shared(base: u32) bool {
    for (memmap.alias_of) |pair| {
        if (pair.of == base) return true;
    }
    return false;
}

fn indexOf(base: u32) ?usize {
    for (memmap.ram, 0..) |entry, index| {
        if (entry.base == base) return index;
    }
    return null;
}

fn allocate(size: u32) Error![]u8 {
    const bytes = std.heap.page_allocator.alloc(u8, size) catch return Error.OutOfMemory;
    @memset(bytes, 0);
    return bytes;
}
