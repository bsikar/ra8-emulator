//! Versioned board composition files: fitted sensors and companion MCUs.
const std = @import("std");
const request = @import("../periph/model/request.zig");

pub const max_fits: usize = 4;
pub const Profile = struct {
    fits: [max_fits]request.Request = undefined,
    count: usize = 0,
};

pub const Error = error{ BadVersion, BadEntry, TooManyFits } || request.Error;

/// Read the small, stable profile format: version=1 plus sensor= or
/// companion= model@endpoint entries. Unknown keys fail closed.
pub fn parse(text: []const u8) Error!Profile {
    var profile: Profile = .{};
    var has_version = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "version=")) {
            if (has_version or !std.mem.eql(u8, line["version=".len..], "1")) return Error.BadVersion;
            has_version = true;
            continue;
        }
        const entry = if (std.mem.startsWith(u8, line, "sensor="))
            line["sensor=".len..]
        else if (std.mem.startsWith(u8, line, "companion="))
            line["companion=".len..]
        else
            return Error.BadEntry;
        if (profile.count == profile.fits.len) return Error.TooManyFits;
        profile.fits[profile.count] = try request.parse(entry);
        profile.count += 1;
    }
    if (!has_version) return Error.BadVersion;
    return profile;
}
