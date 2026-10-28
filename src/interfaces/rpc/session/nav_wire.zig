//! Wire types for navigation and playback RPC methods (Slice 22.4).
const std = @import("std");

pub const Direction = enum(u8) { fwd = 0, back = 1 };

pub const PlayArgs = struct {
    dir: Direction = .fwd,
    speed_milli: u64 = 0,
};

pub const NavQueryKind = enum(u8) {
    frame = 0,
    iteration = 1,
    marker = 2,
    rtos = 3,
    isr = 4,
};

pub const NavQueryArgs = struct {
    kind: NavQueryKind,
    index: u64 = 0,
    name: []const u8 = "",
    pub const max_len = .{ .name = 256 };
};

pub const NavQueryResult = struct {
    found: u8,
    branch: u32 = 0,
    r: u64 = 0,
    phase: u8 = 0,
    o: u32 = 0,
    gap: u8 = 0,
    count: u64 = 0,
    slots: u64 = 0,
    /// A frame's capture time in virtual nanoseconds.
    virtual_ns: u64 = 0,
};

/// The frame pipeline's byte accounting and the rewind's decode count.
pub const FrameStatusResult = struct {
    ram_bytes: u64,
    disk_bytes: u64,
    queue_bytes: u64,
    frames: u64,
    decoded_segments: u64,
};

/// Arms a marker after recording: `place` is a symbol or a `0x` address,
/// and the history is replayed once to index every arrival at it.
pub const MarkerSetArgs = struct {
    name: []const u8,
    place: []const u8,
    pub const max_len = .{ .name = 256, .place = 256 };
};
