//! Fork routing and branch line management for the reverse window (Slice 21.4).
//!
//! The reverse window belongs to one canonical line. An intervention inside
//! the window routes through the Row 20 fork router and creates a new line,
//! preserving the parent line's future. On a fork, the window is cut at the
//! fork point (future slots discarded, window line updated to the child).
//! On a branch switch, the window drops or rebuilds for the new active line.

const std = @import("std");
const engine = @import("window_engine.zig");
const rebuild = @import("window_rebuild.zig");
const position_mod = @import("position.zig");

const ReverseWindow = engine.ReverseWindow;
const Position = engine.Position;

/// Cuts the window at the fork point: drops any future slots past the cursor,
/// and reassigns the window to `new_branch`.
pub fn cutWindowAtFork(w: *ReverseWindow, new_branch: u32) void {
    w.cutAtFork(new_branch);
}

/// Handler invoked when a fork is executed in Session: cuts the window
/// at the fork point.
pub fn noteFork(session: anytype, new_branch: u32) void {
    if (session.window) |w| {
        cutWindowAtFork(w, new_branch);
    }
}

/// Handler invoked on a branch switch in Session: rebuilds or drops
/// the window for `target_branch`.
pub fn noteBranchSwitch(session: anytype, target_branch: u32) !void {
    const w = session.window orelse return;
    if (w.line) |own| {
        if (own == target_branch) return;
    }
    try rebuildWindowForLine(session, target_branch);
}

/// Rebuilds the reverse window for `target_branch` at the session's position.
pub fn rebuildWindowForLine(session: anytype, target_branch: u32) !void {
    const w = session.window orelse return;
    w.drop();
    try w.plant();
    w.line = target_branch;
}

/// Rebuilds the window from a specified base checkpoint up to `end`.
pub fn rebuildWindowFromBase(
    w: *ReverseWindow,
    target_branch: u32,
    base: rebuild.Base,
    end: Position,
) !void {
    w.drop();
    try rebuild.run(w, .{
        .base = base,
        .core = .cpu0,
        .end = end,
    });
    w.line = target_branch;
}
