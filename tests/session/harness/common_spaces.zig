//! Independent raw memory, 12-SpaceId inventory, TrustZone alias topology,
//! cross-core shared-page identity, component storage, and fabric state.
//! Never calls Guest.read() or snapshot codecs, so bus meters, code-line
//! fanouts, touched trackers, and dirty bitmaps stay completely untouched.
const std = @import("std");
const ra8 = @import("ra8");
const hash = @import("common_hash.zig");

const Digest = hash.Digest;
const Hasher = hash.Hasher;
const memmap = ra8.chip.core.memmap;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Board = ra8.board.board.Board;
const SpaceId = ra8.session.history_manifest.SpaceId;
const SpaceAccessor = ra8.session.history_incremental_restore.SpaceAccessor;

pub const all_spaces = [_]SpaceId{
    .cpu0_mram,
    .cpu0_dtcm,
    .cpu0_sram,
    .cpu0_sdram,
    .cpu0_ppb,
    .cpu1_mram,
    .cpu1_dtcm,
    .cpu1_ppb,
    .store_extra,
    .nor_flash,
    .sd_card,
    .eink_buffer,
};

pub const CoreAliases = struct {
    ns_mram: bool,
    ns_sram: bool,
    ns_sdram: bool,
    port_sdram: bool,
};

pub const AliasState = struct {
    cpu0: CoreAliases,
    cpu1: ?CoreAliases = null,
    shared_pages: [memmap.ram.len]?u8 = @splat(null),
};

pub fn regionSlice(store: *const Store, base: u32) ?[]const u8 {
    for (memmap.ram, 0..) |entry, idx| {
        if (entry.base == base) {
            return if (store.pages[idx]) |slice| slice else null;
        }
    }
    return null;
}

fn sameSlice(a: ?[]const u8, b: ?[]const u8) bool {
    const left = a orelse return false;
    const right = b orelse return false;
    return left.ptr == right.ptr and left.len == right.len;
}

pub fn coreAliases(store: *const Store) CoreAliases {
    const port_slice: ?[]const u8 = if (store.port) |p| p.sdram else null;
    return .{
        .ns_mram = sameSlice(regionSlice(store, memmap.mram_base), regionSlice(store, memmap.ns_mram_base)),
        .ns_sram = sameSlice(regionSlice(store, memmap.sram_base), regionSlice(store, memmap.ns_sram_base)),
        .ns_sdram = sameSlice(regionSlice(store, memmap.sdram_base), regionSlice(store, memmap.ns_sdram_base)),
        .port_sdram = sameSlice(regionSlice(store, memmap.sdram_base), port_slice),
    };
}

pub fn sharedPages(first: *const Store, second: *const Store) [memmap.ram.len]?u8 {
    var out: [memmap.ram.len]?u8 = @splat(null);
    for (second.pages, 0..) |page, idx| if (page) |sec_slice| {
        for (first.pages, 0..) |prev, slot| if (prev) |pri_slice| {
            if (sec_slice.ptr == pri_slice.ptr and sec_slice.len == pri_slice.len) {
                out[idx] = @intCast(slot);
                break;
            }
        };
    };
    return out;
}

pub fn aliases(cpu0: *const Store, cpu1: ?*const Store) AliasState {
    var out: AliasState = .{ .cpu0 = coreAliases(cpu0) };
    if (cpu1) |sec| {
        out.cpu1 = coreAliases(sec);
        out.shared_pages = sharedPages(cpu0, sec);
    }
    return out;
}

fn hashSpanWithAlias(h: *Hasher, previous: []const ?[]u8, data: []const u8) void {
    for (previous, 0..) |page, idx| if (page) |held| {
        if (held.ptr == data.ptr and held.len == data.len) {
            h.byte(1);
            h.int(@as(u64, idx));
            return;
        }
    };
    h.byte(0);
    h.bytes(data);
}

/// Complete raw Store digest: every RAM page, alias slot, extra window, and port.
pub fn storeDigest(store: *const Store) Digest {
    var h: Hasher = .{};
    for (store.pages, 0..) |page, idx| {
        h.boolean(page != null);
        if (page) |slice| hashSpanWithAlias(&h, store.pages[0..idx], slice);
    }
    for (store.extra.windows) |win| {
        h.boolean(win != null);
        if (win) |held| {
            h.int(held.base);
            h.bytes(held.bytes);
        }
    }
    h.boolean(store.port != null);
    if (store.port) |port| hashSpanWithAlias(&h, &store.pages, port.sdram);
    return h.final();
}

/// Resolves raw host bytes for any paged SpaceId directly from `memmap` bases
/// or component buffers (never relying on production `getSpaceSlice` indices).
pub fn rawSpaceSlice(
    cpu0: *const Store,
    cpu1: ?*const Store,
    board: *const Board,
    space: SpaceId,
    accessor: ?SpaceAccessor,
) ?[]const u8 {
    if (accessor) |acc| if (acc.getSlice(space)) |slice| return slice;
    return switch (space) {
        .cpu0_mram => regionSlice(cpu0, memmap.mram_base),
        .cpu0_dtcm => regionSlice(cpu0, memmap.dtcm_base),
        .cpu0_sram => regionSlice(cpu0, memmap.sram_base),
        .cpu0_sdram => if (cpu0.port) |p| p.sdram else regionSlice(cpu0, memmap.sdram_base),
        .cpu0_ppb => regionSlice(cpu0, memmap.ppb_base),
        .cpu1_mram => if (cpu1) |s| regionSlice(s, memmap.mram_base) else null,
        .cpu1_dtcm => if (cpu1) |s| regionSlice(s, memmap.dtcm_base) else null,
        .cpu1_ppb => if (cpu1) |s| regionSlice(s, memmap.ppb_base) else null,
        .store_extra => blk: {
            for (cpu0.extra.windows) |w| if (w) |held| break :blk held.bytes;
            if (cpu1) |s| for (s.extra.windows) |w| if (w) |held| break :blk held.bytes;
            break :blk null;
        },
        .nor_flash => board.nor.inverted,
        .eink_buffer => board.panel.planes.image.pixels,
        else => null,
    };
}

fn hashSdImage(allocator: std.mem.Allocator, h: *Hasher, img: *const ra8.components.sd_card.image.Image) !void {
    h.int(img.capacity_blocks);
    const keys = try allocator.alloc(u32, img.blocks.count());
    defer allocator.free(keys);
    var it = img.blocks.keyIterator();
    var idx: usize = 0;
    while (it.next()) |k| : (idx += 1) keys[idx] = k.*;
    std.mem.sort(u32, keys, {}, std.sort.asc(u32));
    h.int(@as(u32, @intCast(keys.len)));
    for (keys) |k| {
        h.int(k);
        h.bytes(img.blocks.get(k).?);
    }
}

fn hashOtpCells(allocator: std.mem.Allocator, h: *Hasher, board: *const Board) !void {
    const map = &board.options.otp.written;
    const keys = try allocator.alloc(u32, map.count());
    defer allocator.free(keys);
    var it = map.keyIterator();
    var idx: usize = 0;
    while (it.next()) |k| : (idx += 1) keys[idx] = k.*;
    std.mem.sort(u32, keys, {}, std.sort.asc(u32));
    h.int(@as(u32, @intCast(keys.len)));
    for (keys) |k| {
        h.int(k);
        h.byte(map.get(k).?);
    }
}

/// Captures all 12 SpaceId backing spaces + both SD block maps + both e-ink
/// planes + OTP written cells + USB stick disk bytes.
pub fn spacesDigest(
    allocator: std.mem.Allocator,
    cpu0: *const Store,
    cpu1: ?*const Store,
    board: *const Board,
    accessor: ?SpaceAccessor,
) !Digest {
    var h: Hasher = .{};
    for (all_spaces) |space| {
        h.auto(space);
        const slice = rawSpaceSlice(cpu0, cpu1, board, space, accessor);
        h.boolean(slice != null);
        if (slice) |bytes| h.bytes(bytes);
    }
    for (cpu0.extra.windows) |w| if (w) |held| {
        h.int(held.base);
        h.bytes(held.bytes);
    };
    if (cpu1) |sec| for (sec.extra.windows) |w| if (w) |held| {
        h.int(held.base);
        h.bytes(held.bytes);
    };
    h.int(board.nor.capacity);
    h.bytes(board.nor.inverted);
    try hashSdImage(allocator, &h, &board.sd.img);
    try hashSdImage(allocator, &h, &board.host_card.img);
    inline for (.{ "image", "glass" }) |plane_name| {
        const plane = @field(board.panel.planes, plane_name);
        h.int(plane.width);
        h.int(plane.height);
        h.bytes(plane.pixels);
    }
    try hashOtpCells(allocator, &h, board);
    h.bytes(board.usb.stick.disk);
    return h.final();
}

pub fn fabricDigest(store: *const Store) Digest {
    var h: Hasher = .{};
    const fab = ra8.board.external.backing.fabricOf(store);
    h.boolean(fab != null);
    if (fab) |f| h.auto(f.state());
    return h.final();
}
