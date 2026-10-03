//! The flags that describe the world the board comes up in: the card on the
//! SPI line, the gauge, the panel, the USB jack and the part's memory split.
//!
//! Its own file so cli.zig keeps room for flags (RA8EMU-428). They read the
//! same way the rest do.
const std = @import("std");
const cli = @import("cli.zig");
const touch_spec = @import("touch_spec.zig");

const Options = cli.Options;
const card_setup = cli.card_setup;

/// Whether the argument at `index` was one of these flags. True walks
/// `index` past any value it took; false leaves it where it was.
pub fn parse(options: *Options, argv: []const []const u8, index: *usize) !bool {
    if (try parseSplit(options, argv, index)) return true;
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--console")) {
        options.console = true;
    } else if (std.mem.eql(u8, flag, "--trace-sd")) {
        options.trace_sd = true;
    } else if (std.mem.eql(u8, flag, "--charge")) {
        options.battery.charging = true;
    } else if (std.mem.eql(u8, flag, "--click")) {
        options.click = true;
    } else if (std.mem.eql(u8, flag, "--bus-errors") or std.mem.eql(u8, flag, "--no-bus-errors")) {
        options.bus_errors = flag[2] == 'b';
    } else if (std.mem.eql(u8, flag, "--blocks") or std.mem.eql(u8, flag, "--no-blocks")) {
        options.blocks = flag[2] == 'b';
    } else if (std.mem.eql(u8, flag, "--sd-size")) {
        options.sd_size_mb = try std.fmt.parseInt(u32, try next(argv, index), 10);
    } else if (std.mem.eql(u8, flag, "--sd") or std.mem.eql(u8, flag, "--sd-save")) {
        options.sd_path = try next(argv, index);
        options.sd_save = flag.len > "--sd".len;
    } else if (std.mem.eql(u8, flag, "--dump-sd")) {
        options.dump_sd = try std.fmt.parseInt(u32, try next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--usb-loop")) {
        options.usb_loop = true;
    } else if (std.mem.eql(u8, flag, "--usb-disk")) {
        options.usb_disk = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--battery")) {
        options.battery.soc_pct = try std.fmt.parseInt(u8, try next(argv, index), 10);
    } else if (std.mem.eql(u8, flag, "--sd-new")) {
        options.sd_new, options.sd_label = try card_setup.newSpec(try next(argv, index));
    } else if (touch_spec.claims(flag)) {
        try touch_spec.take(options, flag, try next(argv, index));
    } else return false;
    return true;
}

/// `--cms N` and `--sfs N`: the Secure code MRAM and SiP flash areas in
/// 32 KB units, as CMSAMON/SFSAMON report them (HUM 51.8.11/51.8.12).
fn parseSplit(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--cms")) {
        options.cms = try area(try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--sfs")) {
        options.sfs = try area(try next(argv, index));
    } else return false;
    return true;
}

/// A nine-bit area, decimal or 0x-prefixed; anything past 0x1FF is refused.
pub fn area(text: []const u8) !u9 {
    return std.fmt.parseInt(u9, text, 0) catch error.BadValue;
}

/// The argument after the flag, or a refusal when the flag was last.
pub fn next(argv: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingValue;
    return argv[index.*];
}
