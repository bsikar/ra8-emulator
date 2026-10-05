//! Which CPU runs the image. The Zig core is the only one, so any name but
//! `zig` is refused as unknown. `--cpu zig` stays accepted for scripts that pass it.
const std = @import("std");

pub const Choice = enum {
    zig,

    /// The value `--cpu` takes, spelled as the enum is.
    pub fn parse(text: []const u8) ?Choice {
        return std.meta.stringToEnum(Choice, text);
    }
};
