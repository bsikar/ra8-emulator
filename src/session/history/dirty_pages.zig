//! Per-space page bitmaps tracking 4 KiB dirty pages for content-addressed checkpoints.
//!
//! Subscribes to the H1-H6 write observer contract (Store.write, DirectMemory.write,
//! NOR flash program/erase, mapped windows, and barriers). Bitmaps are tested and
//! cleared per checkpoint so clean pages can reuse their previous manifest identity
//! without rehashing.
const std = @import("std");
const SpaceId = @import("manifest.zig").SpaceId;
const observer_mod = @import("ra8_chip").core.cpu.memory.observer;
const Initiator = @import("ra8_chip").core.cpu.memory.initiator.Initiator;
const memmap = @import("ra8_chip").core.memmap;

pub const page_size: usize = 0x1000; // 4096 bytes
pub const space_count: usize = 12;

pub const SpaceMap = struct {
    pub const tracked = [_]SpaceId{
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

    pub fn indexOf(space: SpaceId) ?usize {
        inline for (tracked, 0..) |s, i| {
            if (s == space) return i;
        }
        return null;
    }
};

pub const DirtyPages = struct {
    allocator: std.mem.Allocator,
    masks: [space_count][]u64,

    pub fn init(allocator: std.mem.Allocator) !DirtyPages {
        var self: DirtyPages = .{
            .allocator = allocator,
            .masks = undefined,
        };
        for (0..space_count) |i| {
            const pages: usize = switch (SpaceMap.tracked[i]) {
                .cpu0_mram, .cpu1_mram => 512,
                .cpu0_dtcm, .cpu1_dtcm => 32,
                .cpu0_sram => 512,
                .cpu0_sdram, .sd_card => 32768,
                .cpu0_ppb, .cpu1_ppb => 256,
                .store_extra, .nor_flash => 16384,
                .eink_buffer => 1024,
                else => 512,
            };
            const words = (pages + 63) / 64;
            self.masks[i] = try allocator.alloc(u64, words);
            @memset(self.masks[i], 0);
        }
        return self;
    }

    pub fn deinit(self: *DirtyPages) void {
        for (0..space_count) |i| {
            self.allocator.free(self.masks[i]);
        }
        self.* = undefined;
    }

    fn ensureCapacity(self: *DirtyPages, s_idx: usize, needed_words: usize) !void {
        if (needed_words <= self.masks[s_idx].len) return;
        const new_len = @max(needed_words, self.masks[s_idx].len * 2);
        const new_slice = try self.allocator.realloc(self.masks[s_idx], new_len);
        @memset(new_slice[self.masks[s_idx].len..], 0);
        self.masks[s_idx] = new_slice;
    }

    pub fn markDirty(self: *DirtyPages, space: SpaceId, page_index: u32) void {
        const s_idx = SpaceMap.indexOf(space) orelse return;
        const word_idx = page_index / 64;
        self.ensureCapacity(s_idx, word_idx + 1) catch return;
        self.masks[s_idx][word_idx] |= @as(u64, 1) << @intCast(page_index % 64);
    }

    pub fn markRangeDirty(self: *DirtyPages, space: SpaceId, offset: u64, size: u64) void {
        if (size == 0) return;
        const start = @as(u32, @intCast(offset / page_size));
        const end = @as(u32, @intCast((offset + size + page_size - 1) / page_size));
        var p = start;
        while (p < end) : (p += 1) {
            self.markDirty(space, p);
        }
    }

    pub fn markAllDirty(self: *DirtyPages, space: SpaceId) void {
        const s_idx = SpaceMap.indexOf(space) orelse return;
        for (self.masks[s_idx]) |*w| {
            w.* = ~@as(u64, 0);
        }
    }

    pub fn markAllSpacesDirty(self: *DirtyPages) void {
        for (0..space_count) |i| {
            for (self.masks[i]) |*w| {
                w.* = ~@as(u64, 0);
            }
        }
    }

    pub fn isDirty(self: *const DirtyPages, space: SpaceId, page_index: u32) bool {
        const s_idx = SpaceMap.indexOf(space) orelse return false;
        const word_idx = page_index / 64;
        if (word_idx >= self.masks[s_idx].len) return false;
        return (self.masks[s_idx][word_idx] & (@as(u64, 1) << @intCast(page_index % 64))) != 0;
    }

    pub fn clearDirty(self: *DirtyPages, space: SpaceId, page_index: u32) void {
        const s_idx = SpaceMap.indexOf(space) orelse return;
        const word_idx = page_index / 64;
        if (word_idx >= self.masks[s_idx].len) return;
        self.masks[s_idx][word_idx] &= ~(@as(u64, 1) << @intCast(page_index % 64));
    }

    pub fn testAndClear(self: *DirtyPages, space: SpaceId, page_index: u32) bool {
        const s_idx = SpaceMap.indexOf(space) orelse return false;
        const word_idx = page_index / 64;
        if (word_idx >= self.masks[s_idx].len) return false;
        const bit = @as(u64, 1) << @intCast(page_index % 64);
        const was_set = (self.masks[s_idx][word_idx] & bit) != 0;
        self.masks[s_idx][word_idx] &= ~bit;
        return was_set;
    }

    pub fn clearAll(self: *DirtyPages) void {
        for (0..space_count) |i| {
            @memset(self.masks[i], 0);
        }
    }

    pub fn dirtyCount(self: *const DirtyPages, space: SpaceId) usize {
        const s_idx = SpaceMap.indexOf(space) orelse return 0;
        var count: usize = 0;
        for (self.masks[s_idx]) |w| {
            count += @popCount(w);
        }
        return count;
    }

    pub fn storeObserver(self: *DirtyPages) observer_mod.Observer {
        return .{ .ctx = self, .vtable = &store_vtable };
    }

    pub fn componentObserver(self: *DirtyPages, node: *ComponentNode) observer_mod.Observer {
        node.* = .{ .dirty = self, .space = node.space };
        return .{ .ctx = node, .vtable = &ComponentNode.vtable };
    }
};

fn spaceOfBase(base: u32, initiator: Initiator) SpaceId {
    const is_cpu1 = initiator == .cpu1;
    if (base == memmap.mram_base or base == memmap.ns_mram_base) {
        return if (is_cpu1) .cpu1_mram else .cpu0_mram;
    }
    if (base == memmap.dtcm_base) {
        return if (is_cpu1) .cpu1_dtcm else .cpu0_dtcm;
    }
    if (base == memmap.sram_base or base == memmap.ns_sram_base) {
        return .cpu0_sram;
    }
    if (base == memmap.sdram_base or base == memmap.ns_sdram_base) {
        return .cpu0_sdram;
    }
    if (base == memmap.ppb_base) {
        return if (is_cpu1) .cpu1_ppb else .cpu0_ppb;
    }
    return .store_extra;
}

const store_vtable: observer_mod.Observer.VTable = .{
    .bytes = &storeBytes,
    .barrier = &storeBarrier,
};

fn storeBytes(ctx: *anyopaque, write: observer_mod.Write) void {
    const self: *DirtyPages = @ptrCast(@alignCast(ctx));
    const space = spaceOfBase(write.base, write.initiator);
    self.markRangeDirty(space, write.offset, write.pre.len);
}

fn storeBarrier(ctx: *anyopaque, event: observer_mod.Barrier) void {
    const self: *DirtyPages = @ptrCast(@alignCast(ctx));
    switch (event) {
        .wipe, .snapshot_load => self.markAllSpacesDirty(),
        .attach_external => self.markAllDirty(.cpu0_sdram),
        .mapped => |m| self.markRangeDirty(.store_extra, 0, m.size),
        .component => self.markAllSpacesDirty(),
    }
}

pub const ComponentNode = struct {
    dirty: *DirtyPages,
    space: SpaceId,

    pub const vtable: observer_mod.Observer.VTable = .{
        .bytes = &componentBytes,
        .barrier = &componentBarrier,
    };

    fn componentBytes(ctx: *anyopaque, write: observer_mod.Write) void {
        const self: *ComponentNode = @ptrCast(@alignCast(ctx));
        self.dirty.markRangeDirty(self.space, write.offset, write.pre.len);
    }

    fn componentBarrier(ctx: *anyopaque, event: observer_mod.Barrier) void {
        const self: *ComponentNode = @ptrCast(@alignCast(ctx));
        _ = event;
        self.dirty.markAllDirty(self.space);
    }
};
