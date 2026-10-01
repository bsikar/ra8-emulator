//! Which CPU runs the image. Unicorn stays the default until the lockstep
//! harness (RA8EMU-19) shows the Zig core matching it across the corpus.
const std = @import("std");

pub const Choice = enum {
    unicorn,
    zig,

    /// The value `--cpu` takes, spelled as the enum is.
    pub fn parse(text: []const u8) ?Choice {
        return std.meta.stringToEnum(Choice, text);
    }
};
