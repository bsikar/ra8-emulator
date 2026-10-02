//! Per-image instruction budgets for the example table (RA8EMU-71).
//!
//! The table runs every image at one budget, the emulator's default unless
//! the caller names another. Most examples print their verdict long before
//! that. A few do real work first: ra8_io_swap_demo programs and reads back
//! the octal flash through a few thousand XSPI commands and only reaches its
//! "two-backend swap (ram + xs) PASS" line at around 12M instructions, so at
//! the default it reads "budget" with the swap still running.
//!
//! An override here is a floor, not a replacement: an image runs at the
//! larger of its own budget and the caller's, so asking the whole table for
//! more never gives a listed image less.
const std = @import("std");

pub const Override = struct {
    image: []const u8,
    instructions: []const u8,
};

/// Images that need more than the default to reach their verdict, and the
/// budget each was seen to finish inside.
pub const overrides = [_]Override{
    .{ .image = "ra8_io_swap_demo.elf", .instructions = "20000000" },
};

pub fn find(image: []const u8) ?Override {
    for (overrides) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry;
    }
    return null;
}

/// The budget to run `image` at, given the caller's (null means the
/// emulator's default). A caller budget that does not parse is passed
/// through untouched for the emulator to reject.
pub fn pick(image: []const u8, default: ?[]const u8) ?[]const u8 {
    const own = find(image) orelse return default;
    const given = default orelse return own.instructions;
    const asked = std.fmt.parseInt(u64, given, 0) catch return given;
    const floor = std.fmt.parseInt(u64, own.instructions, 10) catch return given;
    return if (floor > asked) own.instructions else given;
}
