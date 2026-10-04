//! Which CPU runs the image. The Zig core is the only one left: Unicorn was
//! dropped as a choice by RA8EMU-606, so `--cpu unicorn` is refused like any
//! other unknown name. `--cpu zig` stays accepted for scripts that pass it.
const std = @import("std");

pub const Choice = enum {
    zig,

    /// The value `--cpu` takes, spelled as the enum is.
    pub fn parse(text: []const u8) ?Choice {
        return std.meta.stringToEnum(Choice, text);
    }
};
