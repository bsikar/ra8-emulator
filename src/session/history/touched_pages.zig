//! The pages written during one checkpoint interval.
//!
//! The checkpoint engine copies the dirty bitmaps (dirty_pages.zig) into
//! one of these as it captures a checkpoint: the set of 4 KiB pages that
//! any write hook (H1-H6) marked since the previous capture, an unchanged
//! write included. It is the record a value-change search trusts to skip
//! an interval: a page absent from the set was not written at all, so no
//! write to it, and no change and change-back, happened in that interval.
//!
//! The set is a copy of the bitmap words, about 12 KiB for a full machine,
//! and lives beside the manifest rather than in it, so the manifest's wire
//! format and Merkle root are untouched. A checkpoint with no record (the
//! first capture, or one recorded before this existed) has no set, and the
//! search replays its interval.
const std = @import("std");
const SpaceId = @import("manifest.zig").SpaceId;
const dirty_pages = @import("dirty_pages.zig");

/// One 4 KiB page of one paged space.
pub const PageKey = struct {
    space: SpaceId,
    page_index: u32,
};

pub const Touched = struct {
    allocator: std.mem.Allocator,
    /// The checkpoint the interval starts at: the set covers the writes
    /// from that checkpoint's capture to this one's.
    since: u32,
    masks: [dirty_pages.space_count][]u64,

    /// Copies the pages `dirty` holds as set right now.
    pub fn fromDirty(allocator: std.mem.Allocator, since: u32, dirty: *const dirty_pages.DirtyPages) !Touched {
        var self: Touched = .{ .allocator = allocator, .since = since, .masks = undefined };
        var made: usize = 0;
        errdefer for (self.masks[0..made]) |m| allocator.free(m);
        for (dirty.masks, 0..) |words, i| {
            self.masks[i] = try allocator.dupe(u64, words);
            made += 1;
        }
        return self;
    }

    pub fn deinit(self: *Touched) void {
        for (self.masks) |words| self.allocator.free(words);
        self.* = undefined;
    }

    /// Whether `key` was written. A space the tracker does not follow is
    /// reported as written: unknown is never "untouched".
    pub fn isTouched(self: *const Touched, key: PageKey) bool {
        const idx = dirty_pages.SpaceMap.indexOf(key.space) orelse return true;
        const word = key.page_index / 64;
        if (word >= self.masks[idx].len) return false;
        return self.masks[idx][word] & (@as(u64, 1) << @intCast(key.page_index % 64)) != 0;
    }

    pub fn encode(self: *const Touched, writer: anytype) !void {
        try writer.writeInt(u32, self.since, .little);
        for (self.masks) |words| {
            try writer.writeInt(u32, @intCast(words.len), .little);
            for (words) |w| {
                try writer.writeInt(u64, w, .little);
            }
        }
    }

    pub fn decodeSlice(allocator: std.mem.Allocator, bytes: []const u8) !Touched {
        if (bytes.len < 4) return error.Truncated;
        var at: usize = 0;
        const since = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        var self: Touched = .{ .allocator = allocator, .since = since, .masks = undefined };
        var made: usize = 0;
        errdefer for (self.masks[0..made]) |m| allocator.free(m);
        for (0..dirty_pages.space_count) |i| {
            if (at + 4 > bytes.len) return error.Truncated;
            const count = std.mem.readInt(u32, bytes[at..][0..4], .little);
            at += 4;
            if (at + count * 8 > bytes.len) return error.Truncated;
            const words = try allocator.alloc(u64, count);
            errdefer allocator.free(words);
            for (0..count) |j| {
                words[j] = std.mem.readInt(u64, bytes[at..][0..8], .little);
                at += 8;
            }
            self.masks[i] = words;
            made += 1;
        }
        return self;
    }

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !Touched {
        const since = try reader.readInt(u32, .little);
        var self: Touched = .{ .allocator = allocator, .since = since, .masks = undefined };
        var made: usize = 0;
        errdefer for (self.masks[0..made]) |m| allocator.free(m);
        for (0..dirty_pages.space_count) |i| {
            const count = try reader.readInt(u32, .little);
            const words = try allocator.alloc(u64, count);
            errdefer allocator.free(words);
            for (0..count) |j| {
                words[j] = try reader.readInt(u64, .little);
            }
            self.masks[i] = words;
            made += 1;
        }
        return self;
    }
};

/// 32-character hex name for the touched-page record object associated with a checkpoint object.
pub fn objectName(object: [16]u8) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("ra8-touched-v1:");
    hasher.update(&object);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var name: [32]u8 = undefined;
    for (digest[0..16], 0..) |byte, i| {
        _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }
    return name;
}
