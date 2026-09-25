//! The command line: the flags the emulator takes and nothing else.
const std = @import("std");

pub const usage =
    \\usage: ra8_emulator <firmware.elf> [--instructions N]
    \\
    \\  --instructions N   stop after N instructions (default 2000000)
    \\
;

pub const Options = struct {
    path: []const u8,
    instructions: usize = 2_000_000,
};

pub fn parse(argv: []const []const u8) !Options {
    if (argv.len < 2) return error.MissingImage;
    var options = Options{ .path = argv[1] };
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--instructions")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.instructions = try std.fmt.parseInt(usize, argv[index], 10);
        } else return error.UnknownFlag;
    }
    return options;
}
