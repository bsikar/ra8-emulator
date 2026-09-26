//! The command line: the flags the emulator takes and nothing else.
const std = @import("std");
const part = @import("part.zig");
const gt911 = @import("../periph/i3c_gt911.zig");
const max17048 = @import("../periph/i3c_max17048.zig");
const sd_format = @import("../periph/sd_format.zig");

pub const usage =
    \\usage: ra8_emulator <firmware.elf> [--instructions N] [--part NAME]
    \\                    [--sd-size MB] [--sd-new FS[:LABEL]] [--touch X,Y]
    \\                    [--battery PCT] [--charge]
    \\
    \\  --instructions N   stop after N instructions (default 2000000)
    \\  --part NAME        ra8d2 (default) or ra8p1, which carries the NPU
    \\  --sd-size MB       size the card on the SPI line (default 32)
    \\  --sd-new FS        format that card: fat16 or fat32, with an
    \\                     optional volume label after a colon
    \\  --touch X,Y        queue a contact on the touch panel, repeatable
    \\  --battery PCT      state-of-charge the fuel gauge reports (default 72)
    \\  --charge           report the charger attached, so the charge rate
    \\                     the gauge answers with is positive
    \\
;

pub const Options = struct {
    path: []const u8,
    instructions: usize = 2_000_000,
    /// Which part the run models. The two share a register map; the RA8P1
    /// also carries the Ethos-U55, so this decides whether that window
    /// answers at all.
    part: part.Part = .ra8d2,
    /// Format the card on the SPI line before the run. Null leaves it the
    /// way it has always come up: blank, with no volume on it at all.
    sd_new: ?sd_format.Kind = null,
    /// The volume label that format gives the card.
    sd_label: []const u8 = "RA8",
    /// The card's size in MiB. Null keeps the image's own default.
    sd_size_mb: ?u32 = null,
    /// Contacts to queue on the touch panel, one drained per frame the
    /// firmware reads.
    touches: [gt911.queue_depth]gt911.Contact = .{gt911.Contact{}} ** gt911.queue_depth,
    touch_count: usize = 0,
    /// What the fuel gauge on the I2C line says is in the battery. The
    /// percent is range-checked by the gauge itself, not here.
    battery: max17048.Battery = .{},
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
        } else if (std.mem.eql(u8, argv[index], "--part")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.part = part.Part.parse(argv[index]) orelse return error.UnknownPart;
        } else if (std.mem.eql(u8, argv[index], "--sd-size")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.sd_size_mb = try std.fmt.parseInt(u32, argv[index], 10);
        } else if (std.mem.eql(u8, argv[index], "--sd-new")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            const spec = argv[index];
            const split = std.mem.indexOfScalar(u8, spec, ':') orelse spec.len;
            options.sd_new = sd_format.Kind.parse(spec[0..split]) orelse return error.UnknownFormat;
            if (split < spec.len) options.sd_label = spec[split + 1 ..];
        } else if (std.mem.eql(u8, argv[index], "--touch")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            if (options.touch_count >= options.touches.len) return error.TooManyTouches;
            options.touches[options.touch_count] = try parseTouch(argv[index]);
            options.touch_count += 1;
        } else if (std.mem.eql(u8, argv[index], "--battery")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.battery.soc_pct = try std.fmt.parseInt(u8, argv[index], 10);
        } else if (std.mem.eql(u8, argv[index], "--charge")) {
            options.battery.charging = true;
        } else return error.UnknownFlag;
    }
    return options;
}

/// "X,Y" as a contact on the panel, in the panel's own coordinates.
fn parseTouch(spec: []const u8) !gt911.Contact {
    const split = std.mem.indexOfScalar(u8, spec, ',') orelse return error.BadTouch;
    return .{
        .x = try std.fmt.parseInt(u16, spec[0..split], 10),
        .y = try std.fmt.parseInt(u16, spec[split + 1 ..], 10),
    };
}
