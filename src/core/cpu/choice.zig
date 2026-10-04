//! Which CPU runs the image. The Zig core is the default (RA8EMU-471): its
//! example table, dual-core corpus and gdb corpus match Unicorn's. Unicorn
//! stays selectable until RA8EMU-255 removes it.
const std = @import("std");

pub const Choice = enum {
    unicorn,
    zig,

    /// The value `--cpu` takes, spelled as the enum is.
    pub fn parse(text: []const u8) ?Choice {
        return std.meta.stringToEnum(Choice, text);
    }
};
