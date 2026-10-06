//! Changing what a shell leaf shows from its title bar (RA8EMU-800). A left
//! press on a leaf's title steps its kind to the next one (empty, board,
//! console, camera, devices, then round to empty), keeping the core it is
//! bound to, so any leaf can become the camera picker (RA8EMU-796) or any
//! other pane without a new layout.
const std = @import("std");
const pane_layout = @import("pane_layout.zig");
const shell_frame = @import("shell_frame.zig");

const Kind = pane_layout.Kind;

/// The kind after `kind`, wrapping from the last back to the first.
pub fn nextKind(kind: Kind) Kind {
    const kinds = std.enums.values(Kind);
    const at = @intFromEnum(kind) + 1;
    return if (at == kinds.len) kinds[0] else @enumFromInt(at);
}

/// The leaf whose title bar holds (`x`, `y`), or null.
pub fn titleAt(layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) ?pane_layout.Index {
    for (solved.panes.items) |placed| {
        if (layout.pane(placed.index) == null) continue;
        if (shell_frame.titleOf(placed.area).contains(x, y)) return placed.index;
    }
    return null;
}

/// Step the kind of the leaf titled at (`x`, `y`). Returns whether a title
/// took the press.
pub fn press(layout: *pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
    const index = titleAt(layout, solved, x, y) orelse return false;
    const pane = layout.pane(index) orelse return false;
    layout.setKind(index, nextKind(pane.kind)) catch return false;
    return true;
}
