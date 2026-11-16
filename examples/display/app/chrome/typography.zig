//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The reader's typography, resolved from the reading-menu choices: which
//! face and size the body is set in, how far apart its lines sit, and how
//! wide the page margins are.

const theme = @import("../theme.zig");
const paint = @import("../paint.zig");
const Settings = @import("../data/settings.zig").Settings;

pub const sizes = [_][:0]const u8{ "1", "2", "3", "4", "5" };
pub const faces = [_][:0]const u8{ "Serif", "Sans" };
pub const spacings = [_][:0]const u8{ "Tight", "Normal", "Loose" };
pub const margins = [_][:0]const u8{ "Narrow", "Normal", "Wide" };
pub const refreshes = [_][:0]const u8{ "Rarely", "Every 8 pages", "Every page" };

/// The reader's five text sizes, smallest first: the three largest reading
/// sizes, then the native 38 px body and 68 px sizes. The 38 px step is the
/// design's page.
const ladder = [_]theme.Size{ .size_3, .size_4, .size_5, .body_38, .title_68 };

/// Line pitch as a percentage of the face's own line box. A label clears
/// its whole box, so lines can never sit closer than that.
const leading_percent = [_]i32{ 100, 110, 125 };
const margin_pixels = [_]i16{ 64, 96, 128 };

pub const Type = struct {
    body: theme.Text,
    heading: theme.Text,
    /// Height of one heading line.
    heading_line: i16,
    leading: i16,
    margin: i16,
};

/// The typography the settings currently select.
pub fn current(settings: Settings) Type {
    const face: theme.Face = if (settings.choice(.face) == 0) .serif else .sans;
    const size = ladder[@min(settings.choice(.size), ladder.len - 1)];
    const body: theme.Text = .{ .face = face, .size = size };
    const heading: theme.Text = .{ .face = face, .weight = .bold, .size = if (size == .title_68) .title_68 else .body_38 };
    const spacing = @min(settings.choice(.spacing), leading_percent.len - 1);
    return .{
        .body = body,
        .heading = heading,
        .heading_line = @intCast(paint.lineHeight(heading) + 1),
        .leading = @intCast(@divTrunc(paint.lineHeight(body) * leading_percent[spacing], 100)),
        .margin = margin_pixels[@min(settings.choice(.margin), margin_pixels.len - 1)],
    };
}
