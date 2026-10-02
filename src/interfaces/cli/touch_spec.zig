//! The `--touch X,Y` spelling, read into a contact on the panel.
//!
//! Its own file so cli.zig keeps room for flags: what a contact spec looks
//! like is a separate question from which flags exist.
const std = @import("std");
const gt911 = @import("../../periph/i3c/i3c_gt911.zig");

/// "X,Y" as a contact on the panel, in the panel's own coordinates.
pub fn parse(spec: []const u8) !gt911.Contact {
    const split = std.mem.indexOfScalar(u8, spec, ',') orelse return error.BadTouch;
    return .{
        .x = try std.fmt.parseInt(u16, spec[0..split], 10),
        .y = try std.fmt.parseInt(u16, spec[split + 1 ..], 10),
    };
}
