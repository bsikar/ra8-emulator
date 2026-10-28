//! Wire codec for state diff RPC operations (Slice 23.5).
const std = @import("std");

pub const RegItem = struct {
    core: u8,
    name: []const u8,
    val_a: u32,
    val_b: u32,
};

pub const PageItem = struct {
    space: u8,
    page_index: u32,
    address: u32,
    has_a: u8,
    obj_a: [16]u8 = @splat(0),
    has_b: u8,
    obj_b: [16]u8 = @splat(0),
};

pub const PeriphItem = struct {
    unit: []const u8,
    offset: u32,
    old_val: u32,
    new_val: u32,
    changed_bytes: u32,
};

pub const DiffWire = struct {
    bytes: []const u8,
    pub const max_len = .{ .bytes = 65536 };
};

pub const DiffArgs = struct {
    a: []const u8,
    b: []const u8,
    pub const max_len = .{ .a = 128, .b = 128 };
};

/// Where one side of a diff stands on its line.
pub const Side = struct {
    branch: u32 = 0,
    r: u64 = 0,
};

pub const DecodedDiff = struct {
    a: Side = .{},
    b: Side = .{},
    /// Rewind-history frames the session held when it answered.
    frames: u16 = 0,
    regs: []RegItem = &.{},
    pages: []PageItem = &.{},
    periphs: []PeriphItem = &.{},

    pub fn deinit(self: *DecodedDiff, allocator: std.mem.Allocator) void {
        for (self.regs) |r| allocator.free(r.name);
        allocator.free(self.regs);
        allocator.free(self.pages);
        for (self.periphs) |p| allocator.free(p.unit);
        allocator.free(self.periphs);
        self.* = undefined;
    }
};

pub fn encode(
    writer: anytype,
    regs: []const RegItem,
    pages: []const PageItem,
    periphs: []const PeriphItem,
) !void {
    return encodeFrames(writer, 0, regs, pages, periphs);
}

/// `encode` with the two sides' positions.
pub fn encodeSides(
    writer: anytype,
    frames: u16,
    a: Side,
    b: Side,
    regs: []const RegItem,
    pages: []const PageItem,
    periphs: []const PeriphItem,
) !void {
    try encodeHead(writer, frames, regs.len, pages.len, periphs.len);
    for ([_]Side{ a, b }) |side| {
        try writer.writeInt(u32, side.branch, .little);
        try writer.writeInt(u64, side.r, .little);
    }
    try encodeBody(writer, regs, pages, periphs);
}

/// `encode` with the count of rewind-history frames the session holds, the
/// range a client may step a frame index through.
pub fn encodeFrames(
    writer: anytype,
    frames: u16,
    regs: []const RegItem,
    pages: []const PageItem,
    periphs: []const PeriphItem,
) !void {
    return encodeSides(writer, frames, .{}, .{}, regs, pages, periphs);
}

fn encodeHead(writer: anytype, frames: u16, regs: usize, pages: usize, periphs: usize) !void {
    try writer.writeInt(u16, @intCast(regs), .little);
    try writer.writeInt(u16, @intCast(pages), .little);
    try writer.writeInt(u16, @intCast(periphs), .little);
    try writer.writeInt(u16, frames, .little);
}

fn encodeBody(writer: anytype, regs: []const RegItem, pages: []const PageItem, periphs: []const PeriphItem) !void {
    for (regs) |r| {
        try writer.writeByte(r.core);
        try writer.writeByte(@intCast(r.name.len));
        try writer.writeAll(r.name);
        try writer.writeInt(u32, r.val_a, .little);
        try writer.writeInt(u32, r.val_b, .little);
    }

    for (pages) |p| {
        try writer.writeByte(p.space);
        try writer.writeInt(u32, p.page_index, .little);
        try writer.writeInt(u32, p.address, .little);
        try writer.writeByte(p.has_a);
        try writer.writeAll(&p.obj_a);
        try writer.writeByte(p.has_b);
        try writer.writeAll(&p.obj_b);
    }

    for (periphs) |p| {
        try writer.writeByte(@intCast(p.unit.len));
        try writer.writeAll(p.unit);
        try writer.writeInt(u32, p.offset, .little);
        try writer.writeInt(u32, p.old_val, .little);
        try writer.writeInt(u32, p.new_val, .little);
        try writer.writeInt(u32, p.changed_bytes, .little);
    }
}

fn decodeRegs(allocator: std.mem.Allocator, bytes: []const u8, at: *usize, count: usize) ![]RegItem {
    const regs = try allocator.alloc(RegItem, count);
    errdefer allocator.free(regs);
    for (0..count) |i| {
        if (at.* + 2 > bytes.len) return error.Truncated;
        const core = bytes[at.*];
        const nlen: usize = bytes[at.* + 1];
        at.* += 2;
        if (at.* + nlen + 8 > bytes.len) return error.Truncated;
        const name = try allocator.dupe(u8, bytes[at.* .. at.* + nlen]);
        at.* += nlen;
        const val_a = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
        const val_b = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
        regs[i] = .{ .core = core, .name = name, .val_a = val_a, .val_b = val_b };
    }
    return regs;
}

fn decodePages(allocator: std.mem.Allocator, bytes: []const u8, at: *usize, count: usize) ![]PageItem {
    const pages = try allocator.alloc(PageItem, count);
    errdefer allocator.free(pages);
    for (0..count) |i| {
        if (at.* + 1 + 4 + 4 + 1 + 16 + 1 + 16 > bytes.len) return error.Truncated;
        const space = bytes[at.*];
        const p_idx = std.mem.readInt(u32, bytes[at.* + 1 ..][0..4], .little);
        const addr = std.mem.readInt(u32, bytes[at.* + 5 ..][0..4], .little);
        const has_a = bytes[at.* + 9];
        var obj_a: [16]u8 = undefined;
        @memcpy(&obj_a, bytes[at.* + 10 .. at.* + 26]);
        const has_b = bytes[at.* + 26];
        var obj_b: [16]u8 = undefined;
        @memcpy(&obj_b, bytes[at.* + 27 .. at.* + 43]);
        at.* += 43;
        pages[i] = .{ .space = space, .page_index = p_idx, .address = addr, .has_a = has_a, .obj_a = obj_a, .has_b = has_b, .obj_b = obj_b };
    }
    return pages;
}

fn decodePeriphs(allocator: std.mem.Allocator, bytes: []const u8, at: *usize, count: usize) ![]PeriphItem {
    const periphs = try allocator.alloc(PeriphItem, count);
    errdefer allocator.free(periphs);
    for (0..count) |i| {
        if (at.* + 1 > bytes.len) return error.Truncated;
        const ulen: usize = bytes[at.*];
        at.* += 1;
        if (at.* + ulen + 16 > bytes.len) return error.Truncated;
        const unit = try allocator.dupe(u8, bytes[at.* .. at.* + ulen]);
        at.* += ulen;
        const offset = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
        const old_val = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
        const new_val = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
        const changed = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
        periphs[i] = .{ .unit = unit, .offset = offset, .old_val = old_val, .new_val = new_val, .changed_bytes = changed };
    }
    return periphs;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !DecodedDiff {
    if (bytes.len < 8) return error.Truncated;
    var at: usize = 0;
    const reg_count = std.mem.readInt(u16, bytes[at..][0..2], .little);
    at += 2;
    const page_count = std.mem.readInt(u16, bytes[at..][0..2], .little);
    at += 2;
    const periph_count = std.mem.readInt(u16, bytes[at..][0..2], .little);
    at += 2;
    const frames = std.mem.readInt(u16, bytes[at..][0..2], .little);
    at += 2;
    if (bytes.len < at + 24) return error.Truncated;
    var sides: [2]Side = undefined;
    for (&sides) |*side| {
        side.branch = std.mem.readInt(u32, bytes[at..][0..4], .little);
        side.r = std.mem.readInt(u64, bytes[at + 4 ..][0..8], .little);
        at += 12;
    }

    const regs = try decodeRegs(allocator, bytes, &at, reg_count);
    errdefer allocator.free(regs);
    const pages = try decodePages(allocator, bytes, &at, page_count);
    errdefer allocator.free(pages);
    const periphs = try decodePeriphs(allocator, bytes, &at, periph_count);
    errdefer allocator.free(periphs);

    return .{ .frames = frames, .a = sides[0], .b = sides[1], .regs = regs, .pages = pages, .periphs = periphs };
}
