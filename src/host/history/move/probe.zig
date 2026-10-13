//! Per-operation fault/kill observation. Null in ordinary callers.
const std = @import("std");
pub const Phase = enum { native_before, native_moved, source_marked, target_created, target_owned, target_marked, file_linked, file_unlinked, target_ready, target_unmarked, source_unmarked, source_deleted };
pub const Probe = struct {
    context: *anyopaque,
    force_fallback: bool = false,
    reached: *const fn (*anyopaque, Phase, std.Io.Dir, []const u8, std.Io.Dir, []const u8) anyerror!void,
};
pub fn reach(probe: ?Probe, phase: Phase, source: std.Io.Dir, from: []const u8, target: std.Io.Dir, to: []const u8) !void {
    if (probe) |hook| try hook.reached(hook.context, phase, source, from, target, to);
}
