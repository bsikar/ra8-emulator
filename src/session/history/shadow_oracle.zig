//! Debug-only shadow memory oracle (Section 5.2 & Section 8).
//!
//! Maintains a shadow baseline of mapped memory pages and verifies after every
//! execution slot that every page that experienced a byte change has at least
//! one corresponding trail write record.
//!
//! A write that bypassed the H1-H6 observation hooks fails immediately with
//! `error.UnhookedWrite`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const store_mod = @import("ra8_chip").core.cpu.memory.store;
const memmap = @import("ra8_chip").core.memmap;
const trail_mod = @import("trail.zig");

pub const page_size: usize = 4096;

pub const MemoryRange = struct {
    base: u32,
    offset: u64,
    len: usize,
};

pub const TrackedRegion = struct {
    base: u32,
    memory: []const u8,
    hashes: []u64,
};

pub const ShadowOracle = struct {
    allocator: Allocator,
    regions: std.ArrayList(TrackedRegion) = .empty,

    pub fn init(allocator: Allocator) ShadowOracle {
        return .{
            .allocator = allocator,
            .regions = .empty,
        };
    }

    pub fn deinit(self: *ShadowOracle) void {
        for (self.regions.items) |r| {
            self.allocator.free(r.hashes);
        }
        self.regions.deinit(self.allocator);
    }

    /// Adds a memory region to track. Takes a snapshot of the current page hashes.
    pub fn trackRegion(self: *ShadowOracle, base: u32, memory: []const u8) !void {
        const page_count = if (memory.len == 0) 0 else (memory.len + page_size - 1) / page_size;
        const hashes = try self.allocator.alloc(u64, page_count);
        errdefer self.allocator.free(hashes);

        var p: usize = 0;
        while (p < page_count) : (p += 1) {
            const start = p * page_size;
            const end = @min(start + page_size, memory.len);
            hashes[p] = hashPage(memory[start..end]);
        }

        try self.regions.append(self.allocator, .{
            .base = base,
            .memory = memory,
            .hashes = hashes,
        });
    }

    /// Tracks all mapped RAM regions from a Store.
    pub fn trackStore(self: *ShadowOracle, store: *const store_mod.Store) !void {
        for (memmap.ram, 0..) |entry, index| {
            if (store.pages[index]) |slice| {
                if (store.owned[index]) {
                    try self.trackRegion(entry.base, slice);
                }
            }
        }
    }

    /// Verifies that every modified page in the tracked regions is covered by
    /// at least one record in `trail_records`.
    pub fn verifySlot(self: *ShadowOracle, trail_records: []const MemoryRange) error{UnhookedWrite}!void {
        for (self.regions.items) |*reg| {
            var p: usize = 0;
            const count = reg.hashes.len;
            while (p < count) : (p += 1) {
                const start = p * page_size;
                const end = @min(start + page_size, reg.memory.len);
                const cur_hash = hashPage(reg.memory[start..end]);
                if (cur_hash != reg.hashes[p]) {
                    const page_start = reg.base + @as(u32, @intCast(start));
                    const page_end = reg.base + @as(u32, @intCast(end));
                    if (!isCovered(page_start, page_end, trail_records)) {
                        return error.UnhookedWrite;
                    }
                    reg.hashes[p] = cur_hash;
                }
            }
        }
    }

    /// Helper to verify using raw `trail_mod.Record` slices.
    pub fn verifyRecording(self: *ShadowOracle, records: []const trail_mod.Record) error{UnhookedWrite}!void {
        var ranges: std.ArrayList(MemoryRange) = .empty;
        defer ranges.deinit(self.allocator);

        for (records) |r| switch (r) {
            .bytes => |b| {
                ranges.append(self.allocator, .{
                    .base = b.base,
                    .offset = b.offset,
                    .len = b.pre.len,
                }) catch return error.UnhookedWrite;
            },
            .barrier => {},
        };
        try self.verifySlot(ranges.items);
    }
};

fn isCovered(page_start: u32, page_end: u32, trail_records: []const MemoryRange) bool {
    for (trail_records) |rec| {
        const rec_start: u64 = @as(u64, rec.base) + rec.offset;
        const rec_end: u64 = rec_start + rec.len;
        if (rec_start < page_end and rec_end > page_start) {
            return true;
        }
    }
    return false;
}

fn hashPage(data: []const u8) u64 {
    var full: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &full, .{});
    return std.mem.readInt(u64, full[0..8], .little);
}
