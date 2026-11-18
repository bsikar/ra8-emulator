//! Parses J-Link Commander's `ShowEmuList USB` listing into probe serials.
//! The listing order is the driver's and is never an identity.
const std = @import("std");

pub const Probe = struct {
    /// The probe's USB serial number, the stable identity of an onboard J-Link.
    serial: u64,
    product: []const u8,
};

const marker = "Serial number: ";
const product_marker = "ProductName: ";

/// Fills `out` from `text`. A serial listed twice makes the listing ambiguous.
pub fn parse(text: []const u8, out: []Probe) ![]Probe {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (!std.mem.startsWith(u8, line, "J-Link[")) continue;
        if (std.mem.indexOf(u8, line, "Connection: USB") == null) continue;
        const probe = try parseLine(line);
        for (out[0..count]) |seen| if (seen.serial == probe.serial) return error.DuplicateSerial;
        if (count == out.len) return error.TooManyProbes;
        out[count] = probe;
        count += 1;
    }
    return out[0..count];
}

fn parseLine(line: []const u8) !Probe {
    const at = std.mem.indexOf(u8, line, marker) orelse return error.BadListing;
    const digits = line[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, digits, ',') orelse digits.len;
    const serial = std.fmt.parseInt(u64, digits[0..end], 10) catch return error.BadListing;
    if (serial == 0) return error.BadListing;
    const name_at = std.mem.indexOf(u8, line, product_marker) orelse return .{ .serial = serial, .product = "" };
    const rest = line[name_at + product_marker.len ..];
    const name_end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    return .{ .serial = serial, .product = rest[0..name_end] };
}

/// The serial as a USB string descriptor spells it: at least twelve digits.
pub fn format(serial: u64, out: *[20]u8) []const u8 {
    var value = serial;
    var at: usize = out.len;
    while (value != 0 or out.len - at < 12) {
        at -= 1;
        out[at] = @intCast('0' + (value % 10));
        value /= 10;
    }
    return out[at..];
}

/// Parses an operator-written serial, with or without the zero padding.
pub fn serialOf(text: []const u8) !u64 {
    if (text.len == 0 or text.len > 20) return error.BadSerial;
    const serial = std.fmt.parseInt(u64, text, 10) catch return error.BadSerial;
    if (serial == 0) return error.BadSerial;
    return serial;
}
