//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Running text. ra8_widget labels draw one line each, so a paragraph is
//! broken into lines here, greedily at spaces, and becomes one label a line.

const std = @import("std");
const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const paint = @import("../paint.zig");

const Builder = tree.Builder;
const Widget = tree.Widget;
const Error = tree.Error;

pub const limits = struct {
    pub const lines: usize = 48;
    pub const line_bytes: usize = 255;
};

/// A block of wrapped text and the height it took.
pub const Block = struct {
    widget: Widget,
    height: i16,
};

/// The longest prefix of `text` that fits `width`, ending at a space where
/// it can. Always at least one byte, so wrapping makes progress.
fn fit(text: []const u8, style: theme.Text, width: i32) usize {
    var scratch: [limits.line_bytes:0]u8 = undefined;
    var best: usize = 0;
    var end: usize = 0;
    while (end < text.len) {
        const next = std.mem.indexOfScalarPos(u8, text, end + 1, ' ') orelse text.len;
        if (next > limits.line_bytes) break;
        @memcpy(scratch[0..next], text[0..next]);
        scratch[next] = 0;
        if (paint.measure(&scratch, style) > width) break;
        best = next;
        end = next;
    }
    return if (best == 0) @min(text.len, @max(end, 1)) else best;
}

/// `text` wrapped to `width` pixels, at most `max_lines` lines, each
/// `leading` pixels tall.
pub fn paragraph(b: *Builder, text: []const u8, style: theme.Text, width: i32, leading: i16, max_lines: usize) Error!Block {
    var lines: [limits.lines]Widget = undefined;
    var count: usize = 0;
    var rest = text;
    while (rest.len > 0 and count < @min(max_lines, limits.lines)) : (count += 1) {
        const taken = fit(rest, style, width);
        const line = try b.fmt("{s}", .{rest[0..taken]});
        lines[count] = tree.sized(try b.label(line, style), leading);
        rest = std.mem.trimLeft(u8, rest[taken..], " ");
    }
    const height: i16 = @intCast(@as(i32, @intCast(count)) * leading);
    return .{ .widget = tree.sized(try b.col(0, lines[0..count]), height), .height = height };
}
