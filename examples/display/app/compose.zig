//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Lays out and paints a widget tree, routes a touch into it, and answers
//! the question the e-ink panel asks after either: which rectangle changed,
//! and does it want a clean refresh or a fast one.

const rw = @import("ra8_widget");
const tree = @import("tree.zig");
const theme = @import("theme.zig");

const Widget = tree.Widget;
const Rect = tree.Rect;

pub const Error = error{ComposeFailed};

/// The region of the panel a redraw touched.
pub const Damage = struct {
    rect: Rect,
    /// True for a whole-screen change that wants the slow, clean waveform.
    quality: bool,
};

pub const frame: Rect = .{ .x = 0, .y = 0, .w = theme.panel.width, .h = theme.panel.height };

const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// Lay out and paint everything that is dirty under `root`.
fn run(root: *Widget) Error!void {
    var damage = empty;
    var hint: rw.types.Refresh = .none;
    var dirty: u16 = 0;
    const status = rw.panel.ra8_widget_panel_compose(root, &frame, &damage, &hint, &dirty);
    if (status != rw.types.err.ok) return error.ComposeFailed;
}

/// Paint a freshly built tree. The whole panel is damaged.
pub fn all(root: *Widget) Error!Damage {
    try run(root);
    return .{ .rect = frame, .quality = true };
}

/// Union the rects of the dirty leaves under `w`, and mark every panel on
/// the way down so the panel compose reaches them.
fn sweep(w: *Widget, acc: *Rect) bool {
    const kids = tree.children(w) orelse {
        if (w.dirty) acc.* = rw.core.rectUnion(acc.*, w.rect);
        return w.dirty;
    };
    var any = false;
    for (kids) |*kid| {
        if (kid.visible and sweep(kid, acc)) any = true;
    }
    if (any) _ = rw.core.ra8_widget_invalidate(w, .fast);
    return any;
}

/// Repaint only the widgets that invalidated themselves since the last
/// compose. Null when nothing did.
pub fn changed(root: *Widget) Error!?Damage {
    var rect = empty;
    if (!sweep(root, &rect)) return null;
    try run(root);
    return .{ .rect = rect, .quality = false };
}

/// Route a touch at panel pixel (`x`, `y`). True when a widget took it.
pub fn touch(root: *Widget, x: i32, y: i32) bool {
    const event: rw.types.Event = .{ .kind = .touch, .reserved = 0, .button_id = 0, .x = x, .y = y };
    const vt = root.vt orelse return false;
    const on_input = vt.on_input orelse return false;
    return on_input(root, &event);
}
