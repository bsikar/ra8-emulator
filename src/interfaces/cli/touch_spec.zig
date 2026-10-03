//! The `--touch X,Y` spelling, read into a contact on the panel.
//!
//! Its own file so cli.zig keeps room for flags: what a contact spec looks
//! like is a separate question from which flags exist.
const std = @import("std");
const gt911 = @import("../../periph/i3c/i3c_gt911.zig");

/// One `--touch` value: "@PATH" names a live host source, anything else is
/// a contact queued before the run.
pub fn take(options: anytype, spec: []const u8) !void {
    if (spec.len > 1 and spec[0] == '@') {
        options.touch_in = spec[1..];
        return;
    }
    if (options.touch_count >= options.touches.len) return error.TooManyTouches;
    options.touches[options.touch_count] = try parse(spec);
    options.touch_count += 1;
}

/// "X,Y" as a contact on the panel, in the panel's own coordinates.
pub fn parse(spec: []const u8) !gt911.Contact {
    const split = std.mem.indexOfScalar(u8, spec, ',') orelse return error.BadTouch;
    return .{
        .x = try std.fmt.parseInt(u16, spec[0..split], 10),
        .y = try std.fmt.parseInt(u16, spec[split + 1 ..], 10),
    };
}
