//! Bounded streaming bundle admission. Entries must be consumed before advancing.
const std = @import("std");

const header = @import("header.zig");
const manifest = @import("manifest.zig");
const names = @import("names.zig");

pub const Limits = struct {
    total_bytes: u64 = 4 * 1024 * 1024 * 1024,
    file_bytes: u64 = 1024 * 1024 * 1024,
    entries: u32 = 4096,
};

pub const Kind = enum { snapshot, root, branches, log, object };
pub const Entry = struct { kind: Kind, name: []const u8, size: u64 };

pub const Reader = struct {
    input: *std.Io.Reader,
    metadata: std.json.Parsed(manifest.Manifest),
    limits: Limits,
    count: u32 = 1,
    total: u64,
    pending: ?u64 = null,
    last: [128]u8 = undefined,
    last_len: usize = 0,
    path_buffer: [128]u8 = undefined,
    logs: bool = false,
    failed: bool = false,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader, limits: Limits) !Reader {
        const first = try header.Header.read(input);
        var path: [128]u8 = undefined;
        if (first.zero() or !std.mem.eql(u8, try first.path(&path), "manifest.json")) {
            return error.MissingManifest;
        }
        const size = try first.size();
        if (size > 8192 or size > limits.file_bytes or limits.entries == 0) return error.TooLarge;
        const total = try charged(0, size, limits);
        var buffer: [8192]u8 = undefined;
        var out = std.Io.Writer.fixed(buffer[0..@intCast(size)]);
        try input.streamExact64(&out, size);
        try padding(input, size);
        return .{
            .input = input,
            .metadata = try manifest.decode(allocator, out.buffered()),
            .limits = limits,
            .total = total,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.metadata.deinit();
    }

    /// Entry names borrow this reader's buffer until the next call.
    pub fn next(self: *Reader) !?Entry {
        if (self.failed) return error.InvalidState;
        if (self.finished) return null;
        errdefer self.failed = true;
        if (self.pending != null) return error.EntryNotConsumed;
        const item = try header.Header.read(self.input);
        if (item.zero()) {
            try self.end();
            return null;
        }
        if (self.count >= self.limits.entries) return error.TooLarge;
        const size = try item.size();
        self.total = try charged(self.total, size, self.limits);
        const path = try item.path(&self.path_buffer);
        const kind = try self.classify(path);
        self.count += 1;
        self.pending = size;
        return .{ .kind = kind, .name = path, .size = size };
    }

    pub fn copy(self: *Reader, output: *std.Io.Writer) !void {
        if (self.failed) return error.InvalidState;
        errdefer self.failed = true;
        const size = self.pending orelse return error.NoEntry;
        try self.input.streamExact64(output, size);
        try padding(self.input, size);
        self.pending = null;
    }

    pub fn readAlloc(self: *Reader, allocator: std.mem.Allocator, max: usize) ![]u8 {
        if (self.failed) return error.InvalidState;
        errdefer self.failed = true;
        const size = self.pending orelse return error.NoEntry;
        if (size > max) return error.TooLarge;
        const bytes = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(bytes);
        var out = std.Io.Writer.fixed(bytes);
        try self.copy(&out);
        return bytes;
    }

    fn classify(self: *Reader, path: []const u8) !Kind {
        const fixed = [_][]const u8{ "manifest.json", "state.ra8snap", "recording/root.bin", "recording/branches.bin" };
        const required: u32 = if (self.metadata.value.recording) 4 else 2;
        if (self.count < required) {
            if (!std.mem.eql(u8, path, fixed[self.count])) return error.BadEntryOrder;
            return switch (self.count) {
                1 => .snapshot,
                2 => .root,
                3 => .branches,
                else => unreachable,
            };
        }
        if (!self.metadata.value.recording) return error.UnexpectedEntry;
        const kind: Kind = blk: {
            if (std.mem.startsWith(u8, path, "recording/log/")) break :blk .log;
            if (std.mem.startsWith(u8, path, "recording/objects/")) break :blk .object;
            return error.UnexpectedEntry;
        };
        const prefix: usize = if (kind == .log) 14 else 18;
        try names.check(path[prefix..]);
        if (std.mem.order(u8, self.last[0..self.last_len], path) != .lt) return error.BadEntryOrder;
        @memcpy(self.last[0..path.len], path);
        self.last_len = path.len;
        self.logs = self.logs or kind == .log;
        return kind;
    }

    fn end(self: *Reader) !void {
        const minimum: u32 = if (self.metadata.value.recording) 5 else 2;
        if (self.count < minimum or (self.metadata.value.recording and !self.logs)) return error.MissingEntry;
        if (self.total > self.limits.total_bytes or self.limits.total_bytes - self.total < 1024) {
            return error.TooLarge;
        }
        const second = header.Header.read(self.input) catch |err| switch (err) {
            error.ReadFailed, error.EndOfStream => return err,
            else => return error.BadTerminator,
        };
        if (!second.zero()) return error.BadTerminator;
        self.total += 1024;
        try zeroTail(self.input, self.limits.total_bytes - self.total);
        self.finished = true;
    }
};

fn charged(total: u64, size: u64, limits: Limits) !u64 {
    if (size > limits.file_bytes or size > std.math.maxInt(u33)) return error.TooLarge;
    const cost = 512 + size + (512 - size % 512) % 512;
    if (total > limits.total_bytes or cost > limits.total_bytes - total) return error.TooLarge;
    return total + cost;
}

fn padding(input: *std.Io.Reader, size: u64) !void {
    const count = (512 - size % 512) % 512;
    var bytes: [512]u8 = undefined;
    const slice = bytes[0..@intCast(count)];
    try input.readSliceAll(slice);
    if (!std.mem.allEqual(u8, slice, 0)) return error.BadPadding;
}

// USTAR writers may pad the final record with additional complete zero blocks.
fn zeroTail(input: *std.Io.Reader, budget: u64) !void {
    var remaining = budget;
    var block: [512]u8 = undefined;
    while (true) {
        const count = try input.readSliceShort(&block);
        if (count == 0) return;
        if (!std.mem.allEqual(u8, block[0..count], 0)) return error.TrailingData;
        if (count != block.len) return error.BadTerminator;
        if (count > remaining) return error.TooLarge;
        remaining -= count;
    }
}
