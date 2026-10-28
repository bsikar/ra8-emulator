//! The frame cache's vocabulary: the tier limits, the file-free cold tier
//! interfaces the application fills, and what a lookup answers.
const std = @import("std");
const frame_types = @import("frame_types.zig");
const picture = @import("checkpoint_picture.zig");

pub const Position = frame_types.Position;
pub const Decoded = picture.Decoded;

const mib: u64 = 1024 * 1024;

/// How much of the RAM budget the hot tier may hold, from the design's
/// table: 1 GiB gives 256 MiB, 512 MiB gives 128, 256 MiB gives 48, and
/// below that nothing (keyframes-only, every frame goes cold).
pub fn hotBytesFor(ram_budget: u64) u64 {
    if (ram_budget >= 1024 * mib) return 256 * mib;
    if (ram_budget >= 512 * mib) return 128 * mib;
    if (ram_budget >= 256 * mib) return 48 * mib;
    return 0;
}

/// One open cold-tier file, the shape of the host's byte file.
pub const File = struct {
    context: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        read: *const fn (context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize,
        write: *const fn (context: *anyopaque, offset: u64, bytes: []const u8) anyerror!void,
        close: *const fn (context: *anyopaque) void,
    };
};

/// Where cold segments go: a delete-on-close file per name.
pub const Backing = struct {
    context: *anyopaque,
    createFn: *const fn (context: *anyopaque, name: []const u8) anyerror!File,
};

pub const Limits = struct {
    /// The hot tier's bytes.
    ram_bytes: u64,
    /// The cold tier's bytes; zero keeps no cold tier.
    disk_bytes: u64 = 0,
    /// The most regenerate markers kept; the oldest go first past it.
    max_markers: usize = 4096,
};

/// What a lookup answered.
pub const Hit = union(enum) {
    /// Nothing at or before the position.
    none,
    /// The frame there was lost to queue overflow: replay rebuilds it.
    regenerate: struct { position: Position, virtual_ns: u64 },
    /// The picture of the newest frame at or before the position.
    frame: Decoded,
};

pub const Report = struct { frames: usize = 0, bytes: u64 = 0 };

/// The segment id every regenerate marker carries: none.
pub const no_segment: u32 = std.math.maxInt(u32);

pub const Entry = struct {
    header: frame_types.FrameHeader,
    segment: u32,
    /// The compressed payload while hot; empty when cold or payload-free.
    payload: []u8 = &.{},
    disk_offset: u64 = 0,
};

pub const Segment = struct {
    id: u32,
    /// The keyframe's position; segments leave oldest key first.
    key: Position,
    ram: u64 = 0,
    file: ?File = null,
    disk_len: u64 = 0,
};

/// What a lookup copies under the lock and decodes outside it.
pub const Snapshot = struct {
    header: frame_types.FrameHeader,
    payload: []u8,
    key_payload: ?[]u8 = null,
};
