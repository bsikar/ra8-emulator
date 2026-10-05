//! The guest-memory section of a snapshot (RA8EMU-659): every region a
//! memory.store.Store owns, and each window it mapped outside memmap.
//!
//! WHAT A STORE OWNS IS WHAT IT SAVES. A Non-secure view is the same bytes
//! as the region it views, and a second core borrows the shared SRAM and
//! SDRAM from the first, so neither is owned and neither is saved twice.
//!
//! ONLY NON-ZERO PAGES ARE WRITTEN. A fresh store is zeroed (store.zig), so
//! a page left out reads back as the zeroes it held; SDRAM alone is 64 MiB.
//!
//! Layout: a region count, then per region its base, length, how many pages
//! follow, and each page as its offset and bytes.
const std = @import("std");
const memmap = @import("../core/memmap.zig");
const store_mod = @import("../core/cpu/memory/store.zig");
const file = @import("file.zig");

pub const Store = store_mod.Store;
pub const page: u32 = 0x1000;

pub const Error = error{ Truncated, Unbacked, SizeMismatch, OutOfMemory };

/// Writes the memory section of `store`.
pub fn save(store: *const Store, writer: anytype) !void {
    try file.writeSectionHeader(writer, .memory, payloadLen(store));
    try writer.writeInt(u32, regionCount(store), .little);
    for (memmap.ram, 0..) |entry, index| {
        if (!store.owned[index]) continue;
        try saveRegion(entry.base, store.pages[index].?, writer);
    }
    for (store.extra.windows) |held| {
        const window = held orelse continue;
        try saveRegion(window.base, window.bytes, writer);
    }
}

/// Fills `store`, freshly made, from a memory section's payload.
pub fn load(store: *Store, payload: []const u8) Error!void {
    var at: usize = 0;
    const count = try int(payload, &at);
    for (0..count) |_| {
        const base = try int(payload, &at);
        const len = try int(payload, &at);
        const bytes = try backing(store, base, len);
        const pages = try int(payload, &at);
        for (0..pages) |_| {
            const offset = try int(payload, &at);
            if (offset >= len) return Error.Truncated;
            const size = @min(page, len - offset);
            if (payload.len - at < size) return Error.Truncated;
            @memcpy(bytes[offset..][0..size], payload[at..][0..size]);
            at += size;
        }
    }
}

fn saveRegion(base: u32, bytes: []const u8, writer: anytype) !void {
    try writer.writeInt(u32, base, .little);
    try writer.writeInt(u32, @intCast(bytes.len), .little);
    try writer.writeInt(u32, liveCount(bytes), .little);
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += page) {
        const chunk = bytes[offset..@min(offset + page, bytes.len)];
        if (zero(chunk)) continue;
        try writer.writeInt(u32, @intCast(offset), .little);
        try writer.writeAll(chunk);
    }
}

/// The host bytes a saved region goes back into, mapping a window outside
/// memmap the way its peripheral did at attach.
fn backing(store: *Store, base: u32, len: u32) Error![]u8 {
    for (memmap.ram) |entry| {
        if (entry.base != base) continue;
        const bytes = store.region(base) orelse return Error.Unbacked;
        if (bytes.len != len) return Error.SizeMismatch;
        return bytes;
    }
    if (store.extra.span(base, len) == null) {
        store.map(base, len) catch |err| return switch (err) {
            error.OutOfMemory => Error.OutOfMemory,
            else => Error.Unbacked,
        };
    }
    return store.extra.span(base, len) orelse Error.Unbacked;
}

fn payloadLen(store: *const Store) u64 {
    var len: u64 = 4;
    for (memmap.ram, 0..) |_, index| {
        if (store.owned[index]) len += regionLen(store.pages[index].?);
    }
    for (store.extra.windows) |held| {
        if (held) |window| len += regionLen(window.bytes);
    }
    return len;
}

fn regionLen(bytes: []const u8) u64 {
    var len: u64 = 12;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += page) {
        const chunk = bytes[offset..@min(offset + page, bytes.len)];
        if (!zero(chunk)) len += 4 + chunk.len;
    }
    return len;
}

fn regionCount(store: *const Store) u32 {
    var count: u32 = 0;
    for (store.owned) |mine| count += @intFromBool(mine);
    for (store.extra.windows) |held| count += @intFromBool(held != null);
    return count;
}

fn liveCount(bytes: []const u8) u32 {
    var count: u32 = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += page) {
        count += @intFromBool(!zero(bytes[offset..@min(offset + page, bytes.len)]));
    }
    return count;
}

fn zero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

fn int(payload: []const u8, at: *usize) Error!u32 {
    if (payload.len - at.* < 4) return Error.Truncated;
    const value = std.mem.readInt(u32, payload[at.*..][0..4], .little);
    at.* += 4;
    return value;
}
