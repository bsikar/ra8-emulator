//! Checkpoint pictures (milestone M7). Every checkpoint stores the
//! composited picture of the last scan at or before it, as one gray
//! keyframe blob in the object space with a checkpoint_picture record
//! naming it. The record is what quota relief honors: the orphan sweep
//! keeps every object a committed record names, and the frame cache's
//! relief never reaches the object space, so a picture is never evicted.
//!
//! The blob is the frame wire form: a keyframe header, then the flate
//! level 1 payload of the gray pixels. Decode verifies the CRC and the
//! pixel count before it hands pixels back.
//!
//! A checkpoint with no scan before it (the display never came up) has
//! no picture; a lookup then answers null, the display-off source.
const std = @import("std");
const frame_types = @import("frame_types.zig");
const frame_crop = @import("frame_crop.zig");
const recorder_mod = @import("recorder.zig");
const record = @import("record.zig");
const replay_mod = @import("replay.zig");
const refs = @import("refs.zig");

pub const Position = frame_types.Position;
pub const Error = error{ NotAKeyframe, BadPixelCount } || frame_types.Error || frame_crop.Error;

/// A gray picture borrowed from its owner, the input of a capture.
pub const Gray = struct {
    position: Position,
    virtual_ns: u64,
    width: u16,
    height: u16,
    pixels: []const u8,
};

/// A decoded picture, owning its pixels.
pub const Decoded = struct {
    position: Position,
    virtual_ns: u64,
    width: u16,
    height: u16,
    pixels: []u8,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.pixels = &.{};
    }
};

/// Where a capture finds the last scan at or before a checkpoint. The
/// application fills it, from the frame cache's lookup. A null answer is
/// "display off". The decoded pixels are the caller's to free.
pub const Source = struct {
    context: *anyopaque,
    lastScanFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, at: Position) anyerror!?Decoded,

    pub fn lastScan(self: Source, allocator: std.mem.Allocator, at: Position) anyerror!?Decoded {
        return self.lastScanFn(self.context, allocator, at);
    }
};

/// The blob a picture is stored as: keyframe header plus compressed pixels.
pub fn encode(allocator: std.mem.Allocator, gray: Gray) ![]u8 {
    const count = @as(usize, gray.width) * gray.height;
    if (gray.pixels.len != count) return Error.BadPixelCount;
    const payload = try frame_crop.compress(allocator, gray.pixels);
    defer allocator.free(payload);
    const header: frame_types.FrameHeader = .{
        .kind = .keyframe,
        .position = gray.position,
        .virtual_ns = gray.virtual_ns,
        .width = gray.width,
        .height = gray.height,
        .rect = .{ .x = 0, .y = 0, .width = gray.width, .height = gray.height },
        .uncompressed_len = @intCast(count),
        .compressed_len = @intCast(payload.len),
        .crc32c = frame_types.FrameHeader.computeCrc(payload),
    };
    const out = try allocator.alloc(u8, frame_types.header_len + payload.len);
    header.encode(out[0..frame_types.header_len]);
    @memcpy(out[frame_types.header_len..], payload);
    return out;
}

/// The picture a blob holds, CRC and pixel count verified.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    const header = try frame_types.FrameHeader.decode(bytes);
    if (header.kind != .keyframe) return Error.NotAKeyframe;
    const total = frame_types.header_len + @as(usize, header.compressed_len);
    if (bytes.len < total) return frame_types.Error.Truncated;
    const payload = bytes[frame_types.header_len..total];
    if (!header.verifyCrc(payload)) return frame_types.Error.BadCrc;
    const count = @as(usize, header.width) * header.height;
    if (header.uncompressed_len != count) return Error.BadPixelCount;
    const pixels = try allocator.alloc(u8, count);
    errdefer allocator.free(pixels);
    try frame_crop.decompress(allocator, payload, pixels);
    return .{
        .position = header.position,
        .virtual_ns = header.virtual_ns,
        .width = header.width,
        .height = header.height,
        .pixels = pixels,
    };
}

/// Pins the picture of the last scan at or before `header.position` for
/// checkpoint `id`: the object lands durable first, then its record
/// stages, ahead of the checkpoint's own record. Returns the object bytes
/// the picture took, or null when no scan exists (display off).
pub fn capture(
    recorder: *recorder_mod.Recorder,
    source: Source,
    allocator: std.mem.Allocator,
    header: record.Header,
    id: u32,
) !?u64 {
    var scan = (try source.lastScan(allocator, header.position)) orelse return null;
    defer scan.deinit(allocator);
    const blob = try encode(allocator, .{
        .position = scan.position,
        .virtual_ns = scan.virtual_ns,
        .width = scan.width,
        .height = scan.height,
        .pixels = scan.pixels,
    });
    defer allocator.free(blob);
    try recorder.checkpointPicture(header, id, blob);
    return blob.len;
}

/// One pinned picture: the checkpoint it belongs to, where that
/// checkpoint sits, and the object holding the blob.
pub const Entry = struct {
    id: u32,
    at: Position,
    object: [16]u8,

    /// The object's file name: lowercase hex of the 128-bit identity.
    pub fn name(self: Entry) refs.Name {
        var out: refs.Name = undefined;
        for (self.object, 0..) |byte, i| {
            _ = std.fmt.bufPrint(out[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
        }
        return out;
    }
};

/// Reads one object's bytes back; the application bridges it to the
/// object space.
pub const Reader = struct {
    context: *anyopaque,
    getFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]u8,
};

/// The pictures a history pins, ordered per line by checkpoint position.
/// Nothing here evicts: the only removal is dropping the whole index.
pub const Index = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        self.entries.deinit(self.allocator);
    }

    /// Adds a picture, keeping the entries ordered by branch, then by
    /// position on the branch. A repeat of a checkpoint id replaces: the
    /// old entry leaves and the new one is placed by its own position, so
    /// the order holds even when the repeat sits somewhere else.
    pub fn add(self: *Index, entry: Entry) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        for (self.entries.items, 0..) |held, i| {
            if (held.id == entry.id and held.at.branch == entry.at.branch) {
                _ = self.entries.orderedRemove(i);
                break;
            }
        }
        var at = self.entries.items.len;
        while (at > 0 and before(entry.at, self.entries.items[at - 1].at)) at -= 1;
        self.entries.insertAssumeCapacity(at, entry);
    }

    /// `order` is null only across branches, which the branch test above
    /// it has already separated, so the unwrap cannot fail.
    fn before(a: Position, b: Position) bool {
        if (a.branch != b.branch) return a.branch < b.branch;
        return Position.order(a, b).? == .lt;
    }

    /// The newest picture whose checkpoint is at or before `at` on its
    /// line, or null (display off).
    pub fn newestAtOrBefore(self: *const Index, at: Position) ?Entry {
        var best: ?Entry = null;
        for (self.entries.items) |entry| {
            const order = Position.order(entry.at, at) orelse continue;
            if (order != .gt) best = entry;
        }
        return best;
    }

    /// Rebuilds the index from a committed segment's records.
    pub fn addFromLog(self: *Index, bytes: []const u8) !void {
        const Walk = struct {
            index: *Index,
            fn visit(walk: @This(), entry: replay_mod.Entry) anyerror!void {
                switch (entry) {
                    .checkpoint_picture => |hit| try walk.index.add(.{
                        .id = hit.checkpoint.id,
                        .at = hit.header.position,
                        .object = hit.checkpoint.object,
                    }),
                    else => {},
                }
            }
        };
        _ = try replay_mod.replay(bytes, Walk{ .index = self }, Walk.visit);
    }

    /// Loads and decodes the picture an entry names.
    pub fn load(self: *const Index, reader: Reader, entry: Entry) !Decoded {
        const name = entry.name();
        const bytes = try reader.getFn(reader.context, self.allocator, &name);
        defer self.allocator.free(bytes);
        return decode(self.allocator, bytes);
    }
};
