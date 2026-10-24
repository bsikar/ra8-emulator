//! Types and hooks for Session-level fork routing (Slice 20.2/20.3).
const std = @import("std");
const Core = @import("event/stream.zig").Core;

pub const NetHook = struct {
    context: *anyopaque,
    closeFlowsFn: *const fn (*anyopaque) void,
};

pub const ConsoleHook = struct {
    context: *anyopaque,
    feedFn: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const CameraHook = struct {
    context: *anyopaque,
    changeFn: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const GraphSink = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, encoded: []const u8) anyerror!void,
};

/// How the application opens a new history when the session loads a
/// different image (new_history.zig). It may attach a new root and
/// recorder to the session before returning.
pub const NewHistoryHook = struct {
    context: *anyopaque,
    startFn: *const fn (context: *anyopaque, core: Core, image: []const u8) anyerror!void,
};
