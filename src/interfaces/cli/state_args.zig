//! `--save-state PATH` and `--load-state PATH` on a `--cpu zig` run
//! (RA8EMU-696): the whole run written once its budget is spent, and read
//! back right after reset, before the first instruction.
const std = @import("std");
const world_flags = @import("world_flags.zig");

pub const Options = struct {
    save: ?[]const u8 = null,
    load: ?[]const u8 = null,

    pub fn wanted(self: Options) bool {
        return self.save != null or self.load != null;
    }
};

pub fn parse(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--save-state")) {
        options.save = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--load-state")) {
        options.load = try world_flags.next(argv, index);
    } else return false;
    return true;
}
