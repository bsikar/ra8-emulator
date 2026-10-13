//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The gui's shared geometry (RA8EMU-1157): the rectangle every shell pane,
//! leaf and picker passes around, aliased from the paint table's own
//! published rect so the render draw list stops being the gui's geometry
//! source. The firmware struct carries no methods, so the helpers live here
//! beside it; leaves that still paint through the draw list convert at their
//! call sites until RA8EMU-1157 closes.

const widget = @import("ra8_widget");

/// A pixel rectangle; `w` or `h` at or below zero is empty.
pub const Rect = widget.types.Rect;

pub fn contains(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

pub fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

pub fn empty(r: Rect) bool {
    return r.w <= 0 or r.h <= 0;
}

/// The smallest rect covering both.
pub fn unionWith(a: Rect, b: Rect) Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{
        .x = x,
        .y = y,
        .w = @max(a.x + a.w, b.x + b.w) - x,
        .h = @max(a.y + a.h, b.y + b.h) - y,
    };
}
