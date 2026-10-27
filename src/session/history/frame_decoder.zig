//! Smooth rewind frame decoder and reverse clock engine (Slice 22.3).
//! Video-player rewind: reverse clock pacing, segment bucket decoding,
//! honest throughput limiting, and hysteresis switching between smooth
//! and keyframe playback.
const std = @import("std");
const position_mod = @import("position.zig");
const frame_cache_mod = @import("frame_cache.zig");
const checkpoint_picture = @import("checkpoint_picture.zig");
const temp_cp_mod = @import("temp_checkpoints.zig");
const nav_index = @import("nav_index.zig");

pub const Position = position_mod.Position;
pub const FrameCache = frame_cache_mod.FrameCache;
pub const PictureIndex = checkpoint_picture.Index;
pub const PictureReader = checkpoint_picture.Reader;

pub const PresentationMode = enum {
    smooth,
    keyframes_only,
};

pub const SourceKind = enum {
    frame_cache,
    decoded_segment,
    checkpoint_picture,
};

/// One decoded frame presented during playback.
pub const DecodedFrame = struct {
    position: Position,
    virtual_ns: u64,
    width: u16,
    height: u16,
    pixels: []u8,
    source: SourceKind,

    pub fn deinit(self: *DecodedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.pixels = &.{};
    }

    pub fn dupe(self: *const DecodedFrame, allocator: std.mem.Allocator) !DecodedFrame {
        const px = try allocator.dupe(u8, self.pixels);
        return .{
            .position = self.position,
            .virtual_ns = self.virtual_ns,
            .width = self.width,
            .height = self.height,
            .pixels = px,
            .source = self.source,
        };
    }
};

/// One presentation bucket: holds the last frame of a speed/60 s window.
pub const Bucket = struct {
    start_ns: u64,
    end_ns: u64,
    frame: ?DecodedFrame = null,

    pub fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        if (self.frame) |*f| f.deinit(allocator);
        self.frame = null;
    }
};

pub const Status = enum {
    ok,
    history_start,
};

pub const TickResult = struct {
    cursor_ns: u64,
    frame: ?DecodedFrame,
    status: Status,
    mode: PresentationMode,
};

/// Computes bucket size in virtual nanoseconds for a given playback speed.
pub fn bucketWidthNs(speed: f64) u64 {
    const raw = (speed * 1_000_000_000.0) / 60.0;
    return @as(u64, @intFromFloat(@max(1.0, @round(raw))));
}

/// The honest throughput limit for uncached reverse playback:
/// min(speed, 0.8 * R / (1 + restore / segment)).
pub fn honestThroughputLimit(speed: f64, replay_rate: f64, restore_ratio: f64) f64 {
    if (replay_rate <= 0.0) return speed;
    const denom = 1.0 + @max(0.0, restore_ratio);
    const max_honest = (0.8 * replay_rate) / denom;
    return @min(speed, max_honest);
}

pub const FrameDecoder = struct {
    allocator: std.mem.Allocator,
    cursor_ns: u64 = 0,
    speed: f64 = 1.0,
    is_max: bool = false,
    mode: PresentationMode = .smooth,
    behind_ns: u64 = 0,
    ahead_ns: u64 = 0,
    replay_rate: f64 = 100.0,
    restore_ratio: f64 = 0.1,
    cache: ?*FrameCache = null,
    pictures: ?*const PictureIndex = null,
    /// The frames the run indexed, which say where a virtual time sits.
    nav: ?*const nav_index.NavIndex = null,
    picture_reader: ?PictureReader = null,
    buckets: std.ArrayList(Bucket) = .empty,
    temp_checkpoints: temp_cp_mod.TempCheckpoints,

    const behind_threshold_ns: u64 = 500 * std.time.ns_per_ms;
    const ahead_threshold_ns: u64 = 2000 * std.time.ns_per_ms;

    pub fn init(allocator: std.mem.Allocator) FrameDecoder {
        return .{
            .allocator = allocator,
            .temp_checkpoints = temp_cp_mod.TempCheckpoints.init(allocator),
        };
    }

    pub fn deinit(self: *FrameDecoder) void {
        self.clearBuckets();
        self.buckets.deinit(self.allocator);
        self.temp_checkpoints.deinit();
    }

    pub fn setCursorNs(self: *FrameDecoder, cursor_ns: u64) void {
        self.cursor_ns = cursor_ns;
    }

    pub fn setSpeed(self: *FrameDecoder, speed: f64) void {
        self.speed = @max(0.001, speed);
        self.is_max = false;
    }

    pub fn setMaxSpeed(self: *FrameDecoder) void {
        self.is_max = true;
        self.mode = .keyframes_only;
    }

    pub fn effectiveSpeed(self: *const FrameDecoder) f64 {
        if (self.is_max) return 1000.0;
        return honestThroughputLimit(self.speed, self.replay_rate, self.restore_ratio);
    }

    pub fn bindCache(self: *FrameDecoder, cache: ?*FrameCache) void {
        self.cache = cache;
    }

    pub fn bindNav(self: *FrameDecoder, nav: ?*const nav_index.NavIndex) void {
        self.nav = nav;
    }

    /// Where a virtual time sits on the line: the position of the newest
    /// indexed frame at or before it. Without the index the time itself
    /// stands in as the round, which only a test's synthetic cache uses.
    fn positionAt(self: *const FrameDecoder, virtual_ns: u64, pos: ?Position) Position {
        if (pos) |given| return given;
        if (self.nav) |nav| {
            var found: ?Position = null;
            for (nav.frames.items) |frame| {
                if (frame.virtual_ns > virtual_ns) break;
                found = frame.position;
            }
            if (found) |at| return at;
            return .{ .branch = 0, .r = 0, .phase = .board, .o = 0 };
        }
        return .{ .branch = 0, .r = @intCast(virtual_ns), .phase = .board, .o = 0 };
    }

    pub fn bindPictures(self: *FrameDecoder, idx: ?*const PictureIndex, reader: ?PictureReader) void {
        self.pictures = idx;
        self.picture_reader = reader;
    }

    pub fn clearBuckets(self: *FrameDecoder) void {
        for (self.buckets.items) |*b| b.deinit(self.allocator);
        self.buckets.clearRetainingCapacity();
    }

    /// Allocates presentation buckets for a segment [start_ns, end_ns] at the current speed.
    pub fn prepareBuckets(self: *FrameDecoder, start_ns: u64, end_ns: u64) !void {
        self.clearBuckets();
        if (end_ns <= start_ns) return;
        const width = bucketWidthNs(self.speed);
        var cur = start_ns;
        while (cur < end_ns) {
            const next = @min(end_ns, cur + width);
            try self.buckets.append(self.allocator, .{ .start_ns = cur, .end_ns = next });
            cur = next;
        }
    }

    /// Stores a candidate frame into its corresponding presentation bucket.
    pub fn storeBucketFrame(self: *FrameDecoder, frame: DecodedFrame) !void {
        for (self.buckets.items) |*b| {
            if (frame.virtual_ns >= b.start_ns and frame.virtual_ns < b.end_ns) {
                if (b.frame) |*existing| existing.deinit(self.allocator);
                b.frame = try frame.dupe(self.allocator);
                return;
            }
        }
    }

    /// Updates hysteresis state based on whether decoder is behind (positive lag) or ahead (negative).
    pub fn updateHysteresis(self: *FrameDecoder, lag_ns: i64) PresentationMode {
        if (self.is_max) {
            self.mode = .keyframes_only;
            return .keyframes_only;
        }
        if (lag_ns > 0) {
            self.behind_ns += @intCast(lag_ns);
            self.ahead_ns = 0;
            if (self.behind_ns >= behind_threshold_ns) {
                self.mode = .keyframes_only;
            }
        } else if (lag_ns < 0) {
            const gain: u64 = @intCast(-lag_ns);
            self.ahead_ns += gain;
            self.behind_ns = 0;
            if (self.ahead_ns >= ahead_threshold_ns) {
                self.mode = .smooth;
            }
        }
        return self.mode;
    }

    /// Advances the reverse clock backward by wall delta.
    pub fn advanceClock(self: *FrameDecoder, dt_wall_ns: u64) Status {
        if (self.is_max) {
            self.mode = .keyframes_only;
            if (self.cursor_ns == 0) return .history_start;
            return .ok;
        }
        const speed_val = self.effectiveSpeed();
        const dt_raw = @as(f64, @floatFromInt(dt_wall_ns)) * speed_val;
        const dt_virt = @as(u64, @intFromFloat(@round(dt_raw)));
        if (self.cursor_ns <= dt_virt) {
            self.cursor_ns = 0;
            return .history_start;
        }
        self.cursor_ns -= dt_virt;
        return .ok;
    }

    /// Ticks the reverse clock backward by wall delta, returning the frame to show.
    pub fn tick(self: *FrameDecoder, dt_wall_ns: u64) !TickResult {
        const status = self.advanceClock(dt_wall_ns);
        const maybe_frame = try self.lookupFrame(self.cursor_ns);
        return .{
            .cursor_ns = self.cursor_ns,
            .frame = maybe_frame,
            .status = status,
            .mode = self.mode,
        };
    }

    /// Looks up newest frame at or before `virtual_ns` following source hierarchy:
    /// 1. Frame cache
    /// 2. Current segment's decoded buckets
    /// 3. Checkpoint picture (keyframes-only)
    pub fn lookupFrame(self: *FrameDecoder, virtual_ns: u64) !?DecodedFrame {
        return self.lookupFrameAt(virtual_ns, null);
    }

    pub fn lookupFrameAt(self: *FrameDecoder, virtual_ns: u64, pos: ?Position) !?DecodedFrame {
        if (self.mode == .smooth) {
            if (try self.lookupCache(virtual_ns, pos)) |frame| return frame;
            if (try self.lookupBucket(virtual_ns)) |frame| return frame;
        }
        if (try self.lookupPicture(virtual_ns, pos)) |frame| return frame;
        return null;
    }

    fn lookupCache(self: *FrameDecoder, virtual_ns: u64, pos: ?Position) !?DecodedFrame {
        const cache_inst = self.cache orelse return null;
        const query_pos = self.positionAt(virtual_ns, pos);
        const hit = try cache_inst.lookup(self.allocator, query_pos);
        switch (hit) {
            .none, .regenerate => return null,
            .frame => |decoded| {
                if (pos == null and decoded.virtual_ns > virtual_ns) {
                    var mut = decoded;
                    mut.deinit(self.allocator);
                    return null;
                }
                return .{
                    .position = decoded.position,
                    .virtual_ns = decoded.virtual_ns,
                    .width = decoded.width,
                    .height = decoded.height,
                    .pixels = decoded.pixels,
                    .source = .frame_cache,
                };
            },
        }
    }

    fn lookupBucket(self: *FrameDecoder, virtual_ns: u64) !?DecodedFrame {
        var idx = self.buckets.items.len;
        while (idx > 0) {
            idx -= 1;
            const b = &self.buckets.items[idx];
            if (b.frame) |*f| {
                if (f.virtual_ns <= virtual_ns) {
                    return try f.dupe(self.allocator);
                }
            }
        }
        return null;
    }

    /// The newest pinned picture whose checkpoint was taken at or before
    /// `virtual_ns`, the restore point of a decode. The cursor's time has
    /// no frame position of its own (the screen may not have changed since
    /// long before it), so the pictures' own times answer: a binary search
    /// over the entries of the line the cursor's frame sits on.
    pub fn lookupRestorePicture(self: *FrameDecoder, virtual_ns: u64) !?DecodedFrame {
        const idx = self.pictures orelse return null;
        const reader = self.picture_reader orelse return null;
        const line = self.positionAt(virtual_ns, null).branch;
        var lo: usize = 0;
        while (lo < idx.entries.items.len and idx.entries.items[lo].at.branch < line) lo += 1;
        var hi = lo;
        while (hi < idx.entries.items.len and idx.entries.items[hi].at.branch == line) hi += 1;
        var best: ?DecodedFrame = null;
        errdefer if (best) |*b| b.deinit(self.allocator);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            var pic = try idx.load(reader, idx.entries.items[mid]);
            if (pic.virtual_ns > virtual_ns) {
                pic.deinit(self.allocator);
                hi = mid;
                continue;
            }
            if (best) |*b| b.deinit(self.allocator);
            best = .{
                .position = pic.position,
                .virtual_ns = pic.virtual_ns,
                .width = pic.width,
                .height = pic.height,
                .pixels = pic.pixels,
                .source = .checkpoint_picture,
            };
            lo = mid + 1;
        }
        return best;
    }

    pub fn lookupPicture(self: *FrameDecoder, virtual_ns: u64, pos: ?Position) !?DecodedFrame {
        const idx = self.pictures orelse return null;
        const reader = self.picture_reader orelse return null;
        const query_pos = self.positionAt(virtual_ns, pos);
        const entry = idx.newestAtOrBefore(query_pos) orelse return null;
        var pic = try idx.load(reader, entry);
        if (pos == null and pic.virtual_ns > virtual_ns) {
            pic.deinit(self.allocator);
            return null;
        }
        return .{
            .position = pic.position,
            .virtual_ns = pic.virtual_ns,
            .width = pic.width,
            .height = pic.height,
            .pixels = pic.pixels,
            .source = .checkpoint_picture,
        };
    }
};
