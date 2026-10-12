//! The decoded-block caches a session keeps, as a plain run keeps them
//! (boot.zig): a block cache watching every store, so a write over code
//! drops its blocks (code_lines.zig).
const std = @import("std");
const decode = @import("ra8_chip").core.cpu.decode;

pub fn form() !*decode.block_cache.BlockCache {
    const cache = try std.heap.page_allocator.create(decode.block_cache.BlockCache);
    errdefer std.heap.page_allocator.destroy(cache);
    cache.init();
    try decode.code_lines.watch(&cache.lines);
    return cache;
}

pub fn drop(cache: *decode.block_cache.BlockCache) void {
    decode.code_lines.unwatch(&cache.lines);
    std.heap.page_allocator.destroy(cache);
}
