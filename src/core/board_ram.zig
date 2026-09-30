//! The host memory behind the board's RAM, and the guest views onto it.
//!
//! Most regions in src/core/memmap.zig need nothing from this file: the CPU
//! model allocates its own pages for them and a store lands where it was
//! made. The two Non-secure aliases are the exception, and they are the
//! reason this file exists. An alias is not a second memory, it is a second
//! address for the same bytes, so the two views have to share one backing
//! store or the model is telling a lie the firmware can catch.
//!
//! IT DID TELL IT. `cpu1_pingpong_ipc`'s CPU1 image writes its boot markers
//! through the Non-secure SRAM view at 0x3210_0200 and explains itself in
//! cpu1_main.c: "CPU1 is a permanent-NS controller, so it reaches shared
//! SRAM through the NS alias at 0x321.....; CPU0's J-Link memprobe sees the
//! same backing store through the standard view." With each view mapped to
//! pages of its own, that last clause was false: the markers were at
//! 0x3210_0200 and nothing at all was at 0x2210_0200.
//!
//! HOW THE SHARING IS DONE. A region named as the Secure side of a pair in
//! `memmap.alias_of` is allocated here, page aligned, and handed to the CPU
//! model by pointer rather than by size. Its Non-secure view is then handed
//! the SAME pointer, so one set of pages answers at both addresses and the
//! aliasing is the CPU model's own memory access rather than anything this
//! tree has to keep in step. Everything else is mapped the way it always
//! was. The allocations belong to the engine that asked for them and are
//! released when it closes.
//!
//! ONE STORE CAN BACK MORE THAN ONE CORE, and that is the second reason
//! this file exists. The RA8D2 is a two-core part: CPU0 and CPU1 run their
//! own images against ONE board, and shared SRAM is shared because it is the
//! same silicon, not because two models are kept in step. A store that
//! already holds pages hands those same pages to the next engine mapped
//! against it, so a second core sees CPU0's stores the instant they land and
//! the model has no cross-core bookkeeping to get wrong. The pages belong to
//! the engine that allocated them, so a borrower must not outlive its owner;
//! `Engine.shareBoardRamWith` names that direction at the call site.
//!
//! THE PAGES ARE ZEROED HERE, and that is not belt and braces. A region the
//! CPU model allocates for itself comes up zeroed, which is the reset state
//! every image and every test has always seen; a region handed over by
//! pointer is whatever the host had in it. The first cut of this file
//! reasoned that fresh anonymous pages are zero-filled by the kernel and
//! left it at that. A test wrote a pattern through one view, closed the
//! engine, opened another, and read the pattern straight back out of two
//! different allocations: the host allocator recycles, so a second engine in
//! the same process inherits the first one's bytes. Reset state is a silicon
//! fact and not something to leave to an allocator, so it is written.
//!
//! THAT COSTS NOTHING AGAINST WHAT IT REPLACES. Mapping the pair by size had
//! the CPU model allocate and zero both views, 128 MB of it for the SDRAM
//! pair; one shared allocation zeroed once is half that.
//!
//! PAGE ALIGNMENT IS CHECKED, NOT ASSUMED. The CPU model requires it of a
//! pointer-mapped region and rejects it after the fact with a generic error,
//! so an unaligned allocation fails here with the alignment named instead of
//! surfacing as an unexplained map failure later.
const std = @import("std");

const c = @import("c.zig");
const memmap = @import("memmap.zig");

pub const Error = error{
    MapFailed,
    OutOfMemory,
};

/// What the CPU model requires of a pointer-mapped region, and what the
/// allocations here are checked against.
pub const page: usize = 0x1000;

/// The permission bits the CPU model wants, out of a region's own.
pub fn protOf(perms: memmap.Region.Perms) c_uint {
    var prot: c_uint = 0;
    if (perms.read) prot |= c.uc.UC_PROT_READ;
    if (perms.write) prot |= c.uc.UC_PROT_WRITE;
    if (perms.exec) prot |= c.uc.UC_PROT_EXEC;
    return prot;
}

/// Whether a span of `len` bytes at `base` is already one of the board's
/// regions. An image's own pages are mapped around what this covers, so a
/// segment landing in SRAM is streamed into the region rather than mapped
/// on top of it.
pub fn covers(base: u32, len: u32) bool {
    for (memmap.ram) |region| {
        if (base >= region.base and @as(u64, base) + len <= region.end()) return true;
    }
    return false;
}

/// The host pages behind the aliased regions, one entry per pair in
/// `memmap.alias_of` and in the same order.
pub const Store = struct {
    backing: [memmap.alias_of.len]?[]u8 = @splat(null),

    /// Release every allocation. Safe to call on a store that never mapped.
    pub fn deinit(self: *Store) void {
        for (&self.backing) |*held| {
            if (held.*) |bytes| std.heap.page_allocator.free(bytes);
            held.* = null;
        }
    }

    /// Whether this store has been put in front of an engine yet, which is
    /// what makes it something a second core can be mapped onto.
    pub fn mapped(self: *const Store) bool {
        for (&self.backing) |held| {
            if (held != null) return true;
        }
        return false;
    }

    /// The pages behind the Secure side of a pair, or null when that region
    /// is not one half of an alias.
    fn pagesFor(self: *const Store, base: u32) ?[]u8 {
        const index = secureIndex(base) orelse return null;
        return self.backing[index];
    }
};

/// Which pair a Secure base is the Secure side of.
fn secureIndex(base: u32) ?usize {
    for (memmap.alias_of, 0..) |pair, index| {
        if (pair.of == base) return index;
    }
    return null;
}

/// The Secure base a Non-secure view is a view of, or null when the base is
/// not a view.
fn viewedRegion(base: u32) ?u32 {
    for (memmap.alias_of) |pair| {
        if (pair.view == base) return pair.of;
    }
    return null;
}

/// Put every region of the board's RAM in front of the engine, allocating
/// the aliased ones here so both of their views answer out of one set of
/// pages.
///
/// The regions are walked in `memmap.ram` order, which is address order, and
/// a Secure region sorts below its own Non-secure view because the view sits
/// 0x1000_0000 above it. So the pages behind a pair are always allocated
/// before the view that has to be given them, and one forward pass is
/// enough.
pub fn mapBoard(handle: ?*c.uc.uc_engine, store: *Store) Error!void {
    for (memmap.ram) |region| {
        const prot = protOf(region.perms);
        if (secureIndex(region.base)) |index| {
            // Already allocated means a second core is being put in front of
            // the board this store already backs: it gets those very pages,
            // which is the whole point of the store outliving one engine.
            const bytes = store.backing[index] orelse blk: {
                const fresh = try allocate(region.size);
                store.backing[index] = fresh;
                break :blk fresh;
            };
            try mapPointer(handle, region.base, region.size, prot, bytes.ptr);
            continue;
        }
        if (viewedRegion(region.base)) |secure| {
            const bytes = store.pagesFor(secure) orelse return Error.MapFailed;
            try mapPointer(handle, region.base, region.size, prot, bytes.ptr);
            continue;
        }
        if (c.uc.uc_mem_map(handle, region.base, region.size, prot) != c.uc.UC_ERR_OK) {
            return Error.MapFailed;
        }
    }
}

/// Pages for a region, zeroed to the reset state the CPU model's own
/// allocation would have given, and checked for the alignment the CPU model
/// requires rather than trusted to have it.
fn allocate(size: u32) Error![]u8 {
    const bytes = std.heap.page_allocator.alloc(u8, size) catch return Error.OutOfMemory;
    if (@intFromPtr(bytes.ptr) % page != 0) {
        std.heap.page_allocator.free(bytes);
        return Error.MapFailed;
    }
    @memset(bytes, 0);
    return bytes;
}

fn mapPointer(handle: ?*c.uc.uc_engine, base: u32, size: u32, prot: c_uint, host: [*]u8) Error!void {
    if (c.uc.uc_mem_map_ptr(handle, base, size, prot, host) != c.uc.UC_ERR_OK) {
        return Error.MapFailed;
    }
}
