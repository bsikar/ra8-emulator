//! The decoded-block caches a session keeps, as a plain run keeps them
//! (boot.zig): a block cache joined to the machine's fanout, so a write
//! over code drops its blocks (code_lines.zig).
const std = @import("std");
const decode = @import("ra8_chip").core.cpu.decode;

pub fn form(fan: *decode.code_lines.Fanout) !*decode.block_cache.BlockCache {
    const cache = try std.heap.page_allocator.create(decode.block_cache.BlockCache);
    errdefer std.heap.page_allocator.destroy(cache);
    cache.init();
    try fan.attach(&cache.lines);
    return cache;
}

pub fn drop(cache: *decode.block_cache.BlockCache, fan: *decode.code_lines.Fanout) void {
    fan.detach(&cache.lines);
    std.heap.page_allocator.destroy(cache);
}
