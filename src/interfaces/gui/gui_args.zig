//! ra8_gui's own flags (RA8EMU-1091): the window settings ra8_emulator has
//! no use for. `take` lifts them out of argv and leaves the rest for
//! cli.parse, so the command line refuses them instead of ignoring them.
const std = @import("std");

/// `--window-stills DIR` keeps numbered PNGs of the window (RA8EMU-500);
/// `--window-stills-every N` keeps frame 0 and every Nth after it.
pub const Window = struct {
    stills: ?[]const u8 = null,
    stills_every: u32 = 1,
};

pub const Taken = struct {
    window: Window,
    /// argv without the window flags, for cli.parse.
    rest: []const []const u8,
};

pub const Error = error{ MissingValue, BadValue, OutOfMemory };

/// Split `argv` into the window flags and everything else.
pub fn take(allocator: std.mem.Allocator, argv: []const []const u8) Error!Taken {
    var window: Window = .{};
    const rest = try allocator.alloc([]const u8, argv.len);
    var kept: usize = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const stills = std.mem.eql(u8, arg, "--window-stills");
        if (!stills and !std.mem.eql(u8, arg, "--window-stills-every")) {
            rest[kept] = arg;
            kept += 1;
            continue;
        }
        i += 1;
        if (i >= argv.len) return error.MissingValue;
        if (stills) {
            window.stills = argv[i];
        } else {
            window.stills_every = std.fmt.parseInt(u32, argv[i], 10) catch return error.BadValue;
            if (window.stills_every == 0) return error.BadValue;
        }
    }
    return .{ .window = window, .rest = rest[0..kept] };
}
