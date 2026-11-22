//! Cached per-function static CFG repository keyed by entry address (RA8EMU-1353).
const std = @import("std");

const builder = @import("builder.zig");
const cfg_mod = @import("cfg.zig");
const core_view = @import("../core_view.zig");
const decode = @import("ra8_chip").core.cpu.decode;
const elf = @import("ra8_board").image.elf;
const extents_mod = @import("extents.zig");
const image_bus = @import("image_bus.zig");

/// Configuration when constructing a `CfgCache`.
pub const Options = struct {
    live: ?core_view.View = null,
    profile: decode.profile.Profile = decode.profile.Profile.m85,
    max_blocks: usize = 1024,
};

/// Owns extracted function extents, a heap-allocated `DecodeCache`, and cached function CFGs.
pub const CfgCache = struct {
    allocator: std.mem.Allocator,
    image: ?elf.Image,
    bus_state: image_bus.ImageBus,
    profile: decode.profile.Profile,
    max_blocks: usize,
    extents: []const extents_mod.FunctionExtent,
    decode_cache: *decode.cache.DecodeCache,
    entries: std.AutoHashMapUnmanaged(u32, cfg_mod.Cfg) = .empty,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, image: ?elf.Image, opts: Options) std.mem.Allocator.Error!CfgCache {
        const decode_cache = try allocator.create(decode.cache.DecodeCache);
        errdefer allocator.destroy(decode_cache);
        decode_cache.* = .{};

        const exts = if (image) |img|
            try extents_mod.collect(allocator, img)
        else
            try allocator.alloc(extents_mod.FunctionExtent, 0);
        errdefer allocator.free(exts);

        return .{
            .allocator = allocator,
            .image = image,
            .bus_state = .{ .image = image, .live = opts.live },
            .profile = opts.profile,
            .max_blocks = opts.max_blocks,
            .extents = exts,
            .decode_cache = decode_cache,
        };
    }

    pub fn deinit(self: *CfgCache) void {
        self.invalidate();
        self.entries.deinit(self.allocator);
        self.allocator.free(self.extents);
        self.allocator.destroy(self.decode_cache);
    }

    /// Return the cached or freshly built CFG covering `address`.
    /// When `address` lies within a known function extent, the enclosing function's entry is used.
    pub fn get(self: *CfgCache, address: u32) std.mem.Allocator.Error!*const cfg_mod.Cfg {
        const norm = address & ~@as(u32, 1);
        const found_ext = extents_mod.findContaining(self.extents, norm);
        const key = if (found_ext) |ext| ext.entry else norm;

        if (self.entries.getPtr(key)) |existing| {
            self.hits += 1;
            return existing;
        }
        self.misses += 1;

        var built = try builder.build(self.allocator, .{
            .image = self.image,
            .bus = self.bus_state.view(),
            .decode_cache = self.decode_cache,
            .profile = self.profile,
            .extents = self.extents,
            .extent = if (found_ext) |ext| ext.* else null,
            .entry = key,
            .max_blocks = self.max_blocks,
        });
        errdefer built.deinit();

        try self.entries.put(self.allocator, key, built);
        return self.entries.getPtr(key).?;
    }

    /// Build and cache CFGs for every seeded function extent; returns cached entry count.
    pub fn prewarmAll(self: *CfgCache) std.mem.Allocator.Error!usize {
        for (self.extents) |ext| {
            _ = try self.get(ext.entry);
        }
        return self.entries.count();
    }

    /// Release all cached function CFGs while keeping symbol extents loaded.
    pub fn invalidate(self: *CfgCache) void {
        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            entry.deinit();
        }
        self.entries.clearRetainingCapacity();
    }
};
