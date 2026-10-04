//! CLI arguments for still and sequential panel captures.
const std = @import("std");
const world_flags = @import("world_flags.zig");

pub const Options = struct {
    frames_out: ?[]const u8 = null,
    frames_every: usize = 1,
};

pub fn parse(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--frames-out")) {
        options.frames_out = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--frames-every")) {
        options.frames_every = try std.fmt.parseInt(usize, try world_flags.next(argv, index), 10);
        if (options.frames_every == 0) return error.BadValue;
    } else return false;
    return true;
}
