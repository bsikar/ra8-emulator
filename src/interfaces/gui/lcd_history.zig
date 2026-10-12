//! Frame history for the shell's LCD pane (RA8EMU-825, piece 4 of 5 under
//! RA8EMU-205). Pure model, no SDL and no session: the feed hands in each
//! panel change as dirty-rectangle deltas with its virtual stamp plus the
//! full grayscale image after the change, and the ring keeps a bounded list
//! of recent frames, a full keyframe copy every `keyframe_every` frames and
//! dirty-rectangle deltas otherwise, under a frame-count and a byte cap that
//! evict whole segments. A scrubber asks which frame a virtual timestamp
//! selects, steps by frame, and reconstructs that frame by walking back to
//! its segment's keyframe and applying the deltas in order. Releasing to
//! live is scrubbing past the newest stamp. The strip's paint lives with the
//! pane; this file holds none.
const std = @import("std");

/// The frames the ring holds before the oldest segment is evicted.
pub const default_max_frames: usize = 64;
/// The stored bytes (keyframes plus delta pixels) the ring holds.
pub const default_max_bytes: usize = 2 * 1024 * 1024;
/// A full keyframe copy lands every this many captured frames.
pub const keyframe_every: usize = 16;

/// One dirty rectangle as the session streams it: grayscale pixels.
pub const Delta = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// w * h grayscale bytes.
    pixels: []const u8,
};

/// The frames captured since the segment's keyframe, up to and including
/// the frame the deltas belong to.
const Frame = struct {
    stamp: u64,
    deltas: []Delta,
};

/// A keyframe copy plus the frames captured against it.
const Segment = struct {
    key: []u8,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
};

pub const History = struct {
    allocator: std.mem.Allocator,
    /// Oldest first.
    segments: std.ArrayListUnmanaged(Segment) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    max_frames: usize = default_max_frames,
    max_bytes: usize = default_max_bytes,
    frames: usize = 0,
    /// Stored key and delta bytes across the ring.
    bytes: usize = 0,
    since_key: usize = 0,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        for (self.segments.items) |*segment| self.clearSegment(segment);
        self.segments.deinit(self.allocator);
    }

    /// Capture a frame: `full` is the complete grayscale image (w * h) after
    /// `deltas` apply, and the deltas' pixels are copied. The history decides
    /// keyframe versus delta per `keyframe_every`.
    pub fn push(self: *History, stamp: u64, full: []const u8, deltas: []const Delta) error{OutOfMemory}!void {
        const area = @as(usize, self.width) * self.height;
        std.debug.assert(full.len == area);
        const headroom = @max(1, self.max_frames / 2);
        const open_frames = if (self.segments.items.len > 0)
            self.segments.items[self.segments.items.len - 1].frames.items.len
        else
            0;
        if (self.since_key == keyframe_every or
            open_frames >= headroom or
            self.segments.items.len == 0)
        {
            const key = try self.allocator.dupe(u8, full);
            errdefer self.allocator.free(key);
            try self.segments.append(self.allocator, .{ .key = key });
            self.bytes += key.len;
            self.since_key = 0;
        }
        const last_segment = &self.segments.items[self.segments.items.len - 1];
        const owned = try self.allocator.alloc(Delta, deltas.len);
        errdefer self.allocator.free(owned);
        var delta_bytes: usize = 0;
        for (deltas, 0..) |delta, i| {
            owned[i] = .{ .x = delta.x, .y = delta.y, .w = delta.w, .h = delta.h, .pixels = undefined };
            owned[i].pixels = try self.allocator.dupe(u8, delta.pixels);
            delta_bytes += delta.pixels.len;
        }
        errdefer for (owned) |delta| self.allocator.free(delta.pixels);
        try last_segment.frames.append(self.allocator, .{ .stamp = stamp, .deltas = owned });
        self.bytes += delta_bytes;
        self.frames += 1;
        self.since_key += 1;
        self.evict();
    }

    /// The newest frame whose stamp is at or before `t`, the scrubber's
    /// position for a virtual timestamp; past the newest stamp that is the
    /// live frame, before the oldest there is nothing to show.
    pub fn scrub(self: *const History, t: u64) ?usize {
        var seen: usize = 0;
        var pick: ?usize = null;
        for (self.segments.items) |segment| {
            for (segment.frames.items) |frame| {
                if (frame.stamp <= t) pick = seen else return pick;
                seen += 1;
            }
        }
        return pick;
    }

    /// Move `by` frames from `from`, clamped to the ring's bounds.
    pub fn step(self: *const History, from: usize, by: isize) ?usize {
        if (self.frames == 0) return null;
        const last = self.frames - 1;
        if (by < 0) {
            const back = @as(usize, @intCast(-by));
            return if (back >= from) 0 else from - back;
        }
        const forward: usize = @intCast(by);
        return @min(from +| forward, last);
    }

    /// The frame `index`'s virtual stamp, oldest frame at 0.
    pub fn stampAt(self: *const History, index: usize) ?u64 {
        var seen: usize = 0;
        for (self.segments.items) |segment| {
            for (segment.frames.items) |frame| {
                if (seen == index) return frame.stamp;
                seen += 1;
            }
        }
        return null;
    }

    /// Rebuild frame `index` into `into` (w * h grayscale): the nearest
    /// keyframe's copy, then the deltas of every frame up to and including
    /// `index`, in capture order.
    pub fn reconstruct(self: *const History, index: usize, into: []u8) void {
        std.debug.assert(into.len == @as(usize, self.width) * self.height);
        var seen: usize = 0;
        for (self.segments.items) |segment| {
            const segment_frames = segment.frames.items.len;
            if (seen + segment_frames > index) {
                @memcpy(into[0..segment.key.len], segment.key);
                // The key already carries the segment's first frame, so its
                // deltas are only applied from the second frame on.
                for (segment.frames.items[1 .. index - seen + 1]) |frame| {
                    for (frame.deltas) |delta| applyDelta(into, self.width, delta);
                }
                return;
            }
            seen += segment_frames;
        }
    }

    fn applyDelta(into: []u8, width: u32, delta: Delta) void {
        for (0..delta.h) |row| {
            const into_row = (delta.y + @as(u32, @intCast(row))) * width + delta.x;
            @memcpy(into[into_row..][0..delta.w], delta.pixels[row * delta.w ..][0..delta.w]);
        }
    }

    /// Evict whole oldest segments until the caps hold; the newest segment
    /// always stays, so a keyframe remains for what the ring keeps.
    fn evict(self: *History) void {
        while (self.segments.items.len > 1 and
            (self.frames > self.max_frames or self.bytes > self.max_bytes))
        {
            const dropped = self.segments.orderedRemove(0);
            self.frames -= dropped.frames.items.len;
            for (dropped.frames.items) |frame| self.bytes -= frameByteCost(frame);
            self.bytes -= dropped.key.len;
            var segment = dropped;
            self.clearSegment(&segment);
        }
    }

    fn frameByteCost(frame: Frame) usize {
        var total: usize = 0;
        for (frame.deltas) |delta| total += delta.pixels.len;
        return total;
    }

    fn clearSegment(self: *History, segment: *Segment) void {
        for (segment.frames.items) |frame| {
            for (frame.deltas) |delta| self.allocator.free(delta.pixels);
            self.allocator.free(frame.deltas);
        }
        segment.frames.deinit(self.allocator);
        self.allocator.free(segment.key);
    }
};
