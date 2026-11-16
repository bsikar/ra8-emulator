//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The bounding box of what differs between two greyscale frames. A rebuilt
//! screen is compared with the frame the panel already shows, so the panel
//! refreshes only the rows and columns that actually changed.

const Rect = @import("tree.zig").Rect;

/// Smallest rect holding every pixel where `now` differs from `before`.
/// Null when the frames are identical. Both are `width` pixels wide.
pub fn bounds(before: []const u8, now: []const u8, width: usize) ?Rect {
    if (width == 0 or before.len != now.len) return null;
    const height = now.len / width;
    var top: usize = height;
    var bottom: usize = 0;
    var left: usize = width;
    var right: usize = 0;
    for (0..height) |y| {
        const a = before[y * width ..][0..width];
        const b = now[y * width ..][0..width];
        var first: usize = 0;
        while (first < width and a[first] == b[first]) first += 1;
        if (first == width) continue;
        var last: usize = width - 1;
        while (a[last] == b[last]) last -= 1;
        top = @min(top, y);
        bottom = y;
        left = @min(left, first);
        right = @max(right, last);
    }
    if (top == height) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .w = @intCast(right - left + 1),
        .h = @intCast(bottom - top + 1),
    };
}
