//! One `--attach NAME@ENDPOINT` ask: which catalog model, and where.
//!
//! The split is at the first '@', because an I2C endpoint carries an '@' of
//! its own: `max17048@i2c:touch@0x37` is the model `max17048` at
//! `i2c:touch@0x37`. A name the catalog does not know is refused here, so a
//! typo fails before the run starts rather than after the board is built.
const std = @import("std");
const endpoint = @import("endpoint.zig");
const parts = @import("parts.zig");

/// How many extra models one run may attach: the RIIC registry's own
/// depth per line (riic_bus.max_devices).
pub const max: usize = 4;

pub const Request = struct {
    name: []const u8,
    at: endpoint.Endpoint,
};

pub const Error = error{ NoModelName, UnknownModel } || endpoint.Error;

pub fn parse(text: []const u8) Error!Request {
    const split = std.mem.indexOfScalar(u8, text, '@') orelse return Error.Malformed;
    if (split == 0) return Error.NoModelName;
    const name = text[0..split];
    if (parts.all.find(name) == null) return Error.UnknownModel;
    return .{ .name = name, .at = try endpoint.parse(text[split + 1 ..]) };
}
