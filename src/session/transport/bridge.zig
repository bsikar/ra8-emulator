const seek_engine = @import("../history/seek_engine.zig");
const std = @import("std");

/// The committed-log bridge the application binds (RA8EMU-1196, unit 17):
/// how the transport reads the served history. Null keeps the seek
/// refusal; bound, a seek plans from the bridge's facts and executes
/// through it.
pub const Bridge = struct {
    context: *anyopaque,
    /// The committed log's facts for planning, gathered fresh per call.
    /// The bridge owns the returned memory until the next call.
    facts: *const fn (*anyopaque) anyerror!seek_engine.Facts,
    /// Put the machine back at a checkpoint's saved state. The name is
    /// the checkpoint record's 128-bit digest as its 32-hex object name.
    restore: *const fn (*anyopaque, object: []const u8) anyerror!void,
    /// Returns the committed log's raw bytes, when available.
    logBytes: ?*const fn (*anyopaque) anyerror![]const u8 = null,
    /// Reads one object of the history's object space by its 32-hex name;
    /// the caller owns the bytes. Null when the bridge cannot.
    readObject: ?*const fn (*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]u8 = null,
};
