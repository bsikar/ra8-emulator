//! Shared fixtures of the frame cache tests: gray pictures, stored
//! keyframe and delta records built the way the worker builds them, and an
//! in-memory cold tier that counts its open files and can be told to fail.
const std = @import("std");
const ra8 = @import("ra8");
const cache_mod = ra8.session.history_frame_cache;
const types = ra8.session.history_frame_types;
const crop = ra8.session.history_frame_crop;

pub const w: u16 = 32;
pub const h: u16 = 16;
pub const px_count = @as(usize, w) * h;

pub fn at(branch: u32, r: u64) types.Position {
    return .{ .branch = branch, .r = r };
}

/// The picture a frame stands for: a keyframe base plus a block painted
/// from `seed`, so every frame rebuilds to known pixels.
pub fn picture(base: u8, seed: u8) [px_count]u8 {
    var out: [px_count]u8 = undefined;
    for (&out, 0..) |*p, i| p.* = base +% @as(u8, @truncate(i));
    if (seed != 0) {
        for (4..9) |y| for (6..14) |x| {
            out[y * w + x] = seed;
        };
    }
    return out;
}

pub fn keyRecord(gpa: std.mem.Allocator, pos: types.Position, gray: []const u8) !types.FrameRecord {
    const payload = try crop.compress(gpa, gray);
    return .{ .header = .{
        .kind = .keyframe,
        .position = pos,
        .virtual_ns = pos.r * 1000,
        .width = w,
        .height = h,
        .rect = .{ .x = 0, .y = 0, .width = w, .height = h },
        .uncompressed_len = px_count,
        .compressed_len = @intCast(payload.len),
        .crc32c = types.FrameHeader.computeCrc(payload),
    }, .payload = payload };
}

pub fn deltaRecord(gpa: std.mem.Allocator, pos: types.Position, key: []const u8, now: []const u8) !types.FrameRecord {
    const rect = crop.diffBox(key, now, w) orelse crop.Rect{};
    var payload: []u8 = &.{};
    if (rect.width > 0) {
        const buf = try gpa.alloc(u8, @as(usize, rect.width) * rect.height);
        defer gpa.free(buf);
        crop.extractCrop(now, w, rect, buf);
        payload = try crop.compress(gpa, buf);
    }
    return .{ .header = .{
        .kind = .delta,
        .position = pos,
        .virtual_ns = pos.r * 1000,
        .width = w,
        .height = h,
        .rect = rect,
        .uncompressed_len = @as(u32, rect.width) * rect.height,
        .compressed_len = @intCast(payload.len),
        .crc32c = types.FrameHeader.computeCrc(payload),
    }, .payload = payload };
}

pub fn put(cache: *cache_mod.FrameCache, gpa: std.mem.Allocator, record: types.FrameRecord) !void {
    var owned = record;
    defer owned.deinit(gpa);
    try cache.put(&owned);
}

/// An in-memory cold tier counting its open files.
pub const Disk = struct {
    gpa: std.mem.Allocator,
    open: usize = 0,
    created: usize = 0,
    /// Failure injection: the next creates / writes answer a full volume.
    fail_create: bool = false,
    fail_write: bool = false,

    const Fake = struct { disk: *Disk, bytes: std.ArrayList(u8) = .empty };

    fn create(context: *anyopaque, name: []const u8) anyerror!cache_mod.File {
        _ = name;
        const self: *Disk = @ptrCast(@alignCast(context));
        if (self.fail_create) return error.NoSpaceLeft;
        const file = try self.gpa.create(Fake);
        file.* = .{ .disk = self };
        self.open += 1;
        self.created += 1;
        return .{ .context = file, .vtable = &vtable };
    }
    const vtable: cache_mod.File.Vtable = .{ .read = read, .write = write, .close = close };

    fn read(context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
        const file: *Fake = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start >= file.bytes.items.len) return 0;
        const n = @min(buffer.len, file.bytes.items.len - start);
        @memcpy(buffer[0..n], file.bytes.items[start..][0..n]);
        return n;
    }
    fn write(context: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const file: *Fake = @ptrCast(@alignCast(context));
        if (file.disk.fail_write) return error.NoSpaceLeft;
        const end: usize = @intCast(offset + bytes.len);
        if (file.bytes.items.len < end) try file.bytes.resize(file.disk.gpa, end);
        @memcpy(file.bytes.items[@intCast(offset)..][0..bytes.len], bytes);
    }
    fn close(context: *anyopaque) void {
        const file: *Fake = @ptrCast(@alignCast(context));
        file.disk.open -= 1;
        file.bytes.deinit(file.disk.gpa);
        file.disk.gpa.destroy(file);
    }
    pub fn backing(self: *Disk) cache_mod.Backing {
        return .{ .context = self, .createFn = create };
    }
};

pub fn expectFrame(cache: *cache_mod.FrameCache, pos: types.Position, want_r: u64, want: []const u8) !void {
    const gpa = std.testing.allocator;
    var hit = try cache.lookup(gpa, pos);
    switch (hit) {
        .frame => |*frame| {
            defer frame.deinit(gpa);
            try std.testing.expectEqual(want_r, frame.position.r);
            try std.testing.expectEqualSlices(u8, want, frame.pixels);
        },
        else => return error.TestUnexpectedResult,
    }
}
