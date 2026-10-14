//! What the settings page's display rows choose: whether a present waits
//! for the display, the most frames a second the window draws, and whether
//! the status strip counts them. The choices are kept as a few lines of
//! text, one `name=value` each; a line this build does not know is passed
//! over, so an older or newer save still reads.
const std = @import("std");

/// The refresh rate assumed for a display that does not say.
pub const fallback_hz: u32 = 60;

/// The most frames a second, or none: as many as the display shows, or with
/// vsync off as many as the host can draw.
pub const Limit = enum(u8) {
    fps30,
    fps60,
    fps120,
    fps144,
    fps240,
    none,

    pub const labels = [_][]const u8{ "30", "60", "120", "144", "240", "None" };

    pub fn hz(self: Limit) ?u32 {
        return switch (self) {
            .fps30 => 30,
            .fps60 => 60,
            .fps120 => 120,
            .fps144 => 144,
            .fps240 => 240,
            .none => null,
        };
    }

    pub fn label(self: Limit) []const u8 {
        return labels[@backingInt(self)];
    }
};

pub const Display = struct {
    /// A present waits for the display's refresh, so no frame tears.
    vsync: bool = true,
    limit: Limit = .none,
    /// The status strip shows the frames a second and what a frame costs.
    counter: bool = false,

    /// Nanoseconds from one frame's start to the next on a display that
    /// refreshes `refresh_mhz` thousandths of a hertz (0 when it does not
    /// say). Zero is no wait at all: vsync off and no limit.
    pub fn interval(self: Display, refresh_mhz: u32) u64 {
        const capped: u64 = if (self.limit.hz()) |hz| std.time.ns_per_s / hz else 0;
        if (!self.vsync) return capped;
        const mhz: u64 = if (refresh_mhz == 0) fallback_hz * 1000 else refresh_mhz;
        return @max(capped, std.time.ns_per_s * 1000 / mhz);
    }

    /// The choices as the saved file's text, in `buf`.
    pub fn write(self: Display, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "vsync={s}\nlimit={s}\ncounter={s}\n", .{ word(self.vsync), self.limit.label(), word(self.counter) }) catch "";
    }

    /// A saved file's text as choices. A line that is missing, unknown or
    /// has a value this build does not offer keeps that choice's default.
    pub fn parse(text: []const u8) Display {
        var display: Display = .{};
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const cut = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = std.mem.trim(u8, line[0..cut], " \t");
            const value = std.mem.trim(u8, line[cut + 1 ..], " \t");
            if (std.mem.eql(u8, name, "vsync")) {
                display.vsync = flag(value) orelse display.vsync;
            } else if (std.mem.eql(u8, name, "counter")) {
                display.counter = flag(value) orelse display.counter;
            } else if (std.mem.eql(u8, name, "limit")) {
                for (Limit.labels, 0..) |known, index| {
                    if (std.mem.eql(u8, value, known)) display.limit = @fromBackingInt(@intCast(index));
                }
            }
        }
        return display;
    }
};

fn word(on: bool) []const u8 {
    return if (on) "on" else "off";
}

fn flag(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return null;
}
