//! Position-stamped navigation entries and comparison callbacks.
const Position = @import("position.zig").Position;
const std = @import("std");

pub const FrameEntry = struct {
    index: u64,
    position: Position,
    virtual_ns: u64 = 0,
};

pub const IterationEntry = struct {
    n: u64,
    position: Position,
    slots: u64,
};

pub const MarkerArrival = struct {
    name: []const u8,
    address: ?u32 = null,
    position: Position,
    nth: u64,
    /// The length of the log the arrival was indexed over; null for an
    /// arrival the history's start fixes for good.
    end: ?u64 = null,
};

pub const RtosSwitch = struct {
    from_thread: u32,
    to_thread: u32,
    position: Position,
    core: u1 = 0,
};

pub const IsrTransition = struct {
    exception: u16,
    is_entry: bool,
    position: Position,
    core: u1 = 0,
};

pub const CompareFn = *const fn (ctx: ?*const anyopaque, a: Position, b: Position) std.math.Order;
