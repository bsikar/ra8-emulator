//! Late-armed marker indexing and on-disk caching (Slice 22.4).
//! When a marker is armed late (after recording), it is indexed by replay
//! and cached in `<session_dir>/index/markers.idx` via the host storage interface.
//! Session code never opens files directly.
const std = @import("std");
const position_mod = @import("position.zig");
const nav_index = @import("nav_index.zig");

pub const Position = position_mod.Position;
pub const NavIndex = nav_index.NavIndex;

pub const magic: [4]u8 = "MIDX".*;
pub const version: u32 = 2;

pub const File = struct {
    context: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        read: *const fn (context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize,
        write: *const fn (context: *anyopaque, offset: u64, bytes: []const u8) anyerror!void,
        close: *const fn (context: *anyopaque) void,
    };
};

pub const Storage = struct {
    context: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        open: *const fn (context: *anyopaque, name: []const u8) anyerror!File,
        create: *const fn (context: *anyopaque, name: []const u8) anyerror!File,
    };

    pub fn open(self: Storage, name: []const u8) anyerror!File {
        return self.vtable.open(self.context, name);
    }

    pub fn create(self: Storage, name: []const u8) anyerror!File {
        return self.vtable.create(self.context, name);
    }
};

/// One cached marker. `end` is the length of the committed log its arrivals
/// were indexed over: a log that has grown past it has arrivals the cache
/// does not hold, so the cache no longer answers.
pub const MarkerData = struct {
    name: []const u8,
    address: u32,
    end: u64,
    arrivals: []const Position,
};

pub fn saveDiskCache(
    allocator: std.mem.Allocator,
    storage: Storage,
    filename: []const u8,
    markers: []const MarkerData,
) !void {
    var file = try storage.create(filename);
    defer file.vtable.close(file.context);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &magic);
    var v_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &v_bytes, version, .little);
    try buf.appendSlice(allocator, &v_bytes);

    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @intCast(markers.len), .little);
    try buf.appendSlice(allocator, &count_bytes);

    for (markers) |m| {
        var name_len: [4]u8 = undefined;
        std.mem.writeInt(u32, &name_len, @intCast(m.name.len), .little);
        try buf.appendSlice(allocator, &name_len);
        try buf.appendSlice(allocator, m.name);

        var addr_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &addr_bytes, m.address, .little);
        try buf.appendSlice(allocator, &addr_bytes);

        var end_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &end_bytes, m.end, .little);
        try buf.appendSlice(allocator, &end_bytes);

        var arr_count: [4]u8 = undefined;
        std.mem.writeInt(u32, &arr_count, @intCast(m.arrivals.len), .little);
        try buf.appendSlice(allocator, &arr_count);

        for (m.arrivals) |p| {
            var p_buf: [24]u8 = undefined;
            serializePosition(p, &p_buf);
            try buf.appendSlice(allocator, &p_buf);
        }
    }

    try file.vtable.write(file.context, 0, buf.items);
}

pub fn loadDiskCache(
    allocator: std.mem.Allocator,
    storage: Storage,
    filename: []const u8,
) ![]MarkerData {
    var file = storage.open(filename) catch return error.NotFound;
    defer file.vtable.close(file.context);

    var header: [12]u8 = undefined;
    const read_len = try file.vtable.read(file.context, 0, &header);
    if (read_len < 12) return error.BadFormat;
    if (!std.mem.eql(u8, header[0..4], &magic)) return error.BadFormat;
    const ver = std.mem.readInt(u32, header[4..8], .little);
    if (ver != version) return error.BadFormat;
    const count = std.mem.readInt(u32, header[8..12], .little);

    var list: std.ArrayListUnmanaged(MarkerData) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.arrivals);
        }
        list.deinit(allocator);
    }

    var offset: u64 = 12;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var n_len_buf: [4]u8 = undefined;
        if (try file.vtable.read(file.context, offset, &n_len_buf) < 4) return error.BadFormat;
        offset += 4;
        const n_len = std.mem.readInt(u32, &n_len_buf, .little);

        const name = try allocator.alloc(u8, n_len);
        errdefer allocator.free(name);
        if (try file.vtable.read(file.context, offset, name) < n_len) return error.BadFormat;
        offset += n_len;

        var addr_buf: [4]u8 = undefined;
        if (try file.vtable.read(file.context, offset, &addr_buf) < 4) return error.BadFormat;
        offset += 4;
        const address = std.mem.readInt(u32, &addr_buf, .little);

        var end_buf: [8]u8 = undefined;
        if (try file.vtable.read(file.context, offset, &end_buf) < 8) return error.BadFormat;
        offset += 8;
        const end = std.mem.readInt(u64, &end_buf, .little);

        var a_len_buf: [4]u8 = undefined;
        if (try file.vtable.read(file.context, offset, &a_len_buf) < 4) return error.BadFormat;
        offset += 4;
        const a_len = std.mem.readInt(u32, &a_len_buf, .little);

        const arrivals = try allocator.alloc(Position, a_len);
        errdefer allocator.free(arrivals);

        var j: usize = 0;
        while (j < a_len) : (j += 1) {
            var p_buf: [24]u8 = undefined;
            if (try file.vtable.read(file.context, offset, &p_buf) < 24) return error.BadFormat;
            offset += 24;
            arrivals[j] = deserializePosition(&p_buf);
        }

        try list.append(allocator, .{
            .name = name,
            .address = address,
            .end = end,
            .arrivals = arrivals,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeDiskCache(allocator: std.mem.Allocator, data: []MarkerData) void {
    for (data) |item| {
        allocator.free(item.name);
        allocator.free(item.arrivals);
    }
    allocator.free(data);
}

/// The replay a late marker is indexed by, supplied by the application
/// layer that owns the machine: it appends the position of every arrival at
/// `address` over the recorded history, in order.
pub const Replay = struct {
    context: *anyopaque,
    runFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        address: u32,
        out: *std.ArrayListUnmanaged(Position),
    ) anyerror!void,
};

/// Arms a marker after recording. A cached answer for the same name and
/// address, indexed over a log of the same `end`, feeds the index without
/// replaying; a log grown past a cached end drops that cache entry. Otherwise `replay` walks the
/// recorded history once, its arrivals feed the index, and they are cached
/// through `storage` (a failed cache write never fails the arm). Answers the
/// number of arrivals the marker now has.
pub fn armLate(
    allocator: std.mem.Allocator,
    storage: ?Storage,
    index_file: []const u8,
    name: []const u8,
    address: u32,
    end: u64,
    replay: Replay,
    target_nav: *NavIndex,
) !usize {
    var existing_cached: ?[]MarkerData = null;
    defer if (existing_cached) |cached| freeDiskCache(allocator, cached);

    if (storage) |st| {
        if (loadDiskCache(allocator, st, index_file)) |cached| {
            for (cached) |m| {
                if (std.mem.eql(u8, m.name, name) and m.address == address and m.end == end) {
                    defer freeDiskCache(allocator, cached);
                    for (m.arrivals) |p| {
                        _ = try target_nav.addMarkerArrivalAt(m.name, m.address, p, end);
                    }
                    return m.arrivals.len;
                }
            }
            existing_cached = cached;
        } else |_| {}
    }

    var arrivals: std.ArrayListUnmanaged(Position) = .empty;
    defer arrivals.deinit(allocator);
    try replay.runFn(replay.context, allocator, address, &arrivals);
    for (arrivals.items) |pos| {
        _ = try target_nav.addMarkerArrivalAt(name, address, pos, end);
    }

    if (storage) |st| {
        var to_save: std.ArrayListUnmanaged(MarkerData) = .empty;
        defer to_save.deinit(allocator);
        if (existing_cached) |prev| {
            for (prev) |m| {
                if (!std.mem.eql(u8, m.name, name) and m.end == end) try to_save.append(allocator, m);
            }
        }
        try to_save.append(allocator, .{ .name = name, .address = address, .end = end, .arrivals = arrivals.items });
        saveDiskCache(allocator, st, index_file, to_save.items) catch {};
    }
    return arrivals.items.len;
}

/// Feeds every cached marker into `target_nav`, as a reopened history does
/// so `seek marker` needs no replay. A missing cache is not an error, and a
/// marker cached over a shorter log than `end` is left out.
pub fn loadInto(
    allocator: std.mem.Allocator,
    storage: Storage,
    index_file: []const u8,
    end: u64,
    target_nav: *NavIndex,
) !void {
    const cached = loadDiskCache(allocator, storage, index_file) catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };
    defer freeDiskCache(allocator, cached);
    for (cached) |m| {
        if (m.end != end) continue;
        for (m.arrivals) |p| _ = try target_nav.addMarkerArrivalAt(m.name, m.address, p, end);
    }
}

fn serializePosition(p: Position, out: *[24]u8) void {
    std.mem.writeInt(u32, out[0..4], p.branch, .little);
    std.mem.writeInt(u64, out[4..12], p.r, .little);
    out[12] = @backingInt(p.phase);
    std.mem.writeInt(u32, out[13..17], p.o, .little);
    out[17] = @backingInt(p.gap);
    @memset(out[18..24], 0);
}

fn deserializePosition(buf: *const [24]u8) Position {
    return .{
        .branch = std.mem.readInt(u32, buf[0..4], .little),
        .r = std.mem.readInt(u64, buf[4..12], .little),
        .phase = @fromBackingInt(@intCast(buf[12])),
        .o = std.mem.readInt(u32, buf[13..17], .little),
        .gap = @fromBackingInt(@intCast(buf[17])),
    };
}
